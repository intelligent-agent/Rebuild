// Power-loss detection prototype (Rebuild#140)
//
// Samples one ADC pin on its own fast timer and compares each sample with a
// threshold. Nothing is reported while the input is good - the pin's normal
// analog_in reports are unaffected - so the serial link carries no extra
// traffic. On the first sample below the threshold it drives an output pin
// high (UC-INT-1, STM32 PF1 -> A64 PG3), reports the trip to the host once,
// and from then on toggles that pin as a heartbeat: the A64 timestamps the
// edges, and when they stop, this MCU has lost power.
//
// This file may be distributed under the terms of the GNU GPLv3 license.

#include "basecmd.h" // oid_alloc
#include "board/gpio.h" // struct gpio_adc
#include "board/irq.h" // irq_disable
#include "board/misc.h" // timer_read_time
#include "command.h" // DECL_COMMAND
#include "sched.h" // DECL_TASK
#include "recovery_store.h"

#define RECOVERY_QUEUE 32
struct recovery_sample {
    uint32_t clock, sequence;
    int32_t position[4];
};
static struct recovery_sample recovery_queue[RECOVERY_QUEUE], recovery_latest;
static uint8_t recovery_head, recovery_count, recovery_have_sample;
static uint32_t recovery_run, recovery_applied, recovery_dropped;
static struct recovery_record recovery_snapshot;
static uint8_t recovery_saved;
static void
recovery_apply(uint32_t now)
{
    while (recovery_count && !timer_is_before(now, recovery_queue[recovery_head].clock)) {
        recovery_latest = recovery_queue[recovery_head];
        recovery_have_sample = 1;
        recovery_applied++;
        recovery_head = (recovery_head+1) % RECOVERY_QUEUE;
        recovery_count--;
    }
}

struct power_monitor {
    struct timer timer;
    uint32_t rest_ticks, heartbeat_ticks, trip_clock;
    struct gpio_adc adc;
    struct gpio_out out;
    uint16_t threshold, trip_value, last_value;
    uint32_t samples;
    uint8_t tripped, reported, level, armed, below_count, required_samples;
};

static struct task_wake power_monitor_wake;

static uint_fast8_t
power_monitor_event(struct timer *timer)
{
    struct power_monitor *p = container_of(timer, struct power_monitor, timer);
    if (p->tripped) {
        p->level = !p->level;
        gpio_out_write(p->out, p->level);
        p->timer.waketime += p->heartbeat_ticks;
        return SF_RESCHEDULE;
    }
    // The ADC is shared with analog_in: gpio_adc_sample() starts this pin's
    // conversion when the converter is free and says how long to wait.
    recovery_apply(timer_read_time());
    uint32_t sample_delay = gpio_adc_sample(p->adc);
    if (sample_delay) {
        p->timer.waketime = timer_read_time() + sample_delay;
        return SF_RESCHEDULE;
    }
    uint16_t value = gpio_adc_read(p->adc);
    p->last_value = value;
    p->samples++;
    if (value < p->threshold && p->armed)
        p->below_count++;
    else
        p->below_count = 0;
    if (p->below_count >= p->required_samples) {
        p->tripped = 1;
        p->level = 1;
        gpio_out_write(p->out, 1);
        p->trip_clock = timer_read_time();
        p->trip_value = value;
        if (recovery_have_sample) {
            recovery_snapshot.run = recovery_run;
            recovery_snapshot.sequence = recovery_latest.sequence;
            recovery_snapshot.sample_clock = recovery_latest.clock;
            recovery_snapshot.trip_clock = p->trip_clock;
            memcpy(recovery_snapshot.position, recovery_latest.position,
                   sizeof(recovery_snapshot.position));
        }
        sched_wake_task(&power_monitor_wake);
        p->timer.waketime = p->trip_clock + p->heartbeat_ticks;
        return SF_RESCHEDULE;
    }
    p->timer.waketime = timer_read_time() + p->rest_ticks;
    return SF_RESCHEDULE;
}

void
command_config_power_monitor(uint32_t *args)
{
    struct power_monitor *p = oid_alloc(
        args[0], command_config_power_monitor, sizeof(*p));
    p->adc = gpio_adc_setup(args[1]);
    p->out = gpio_out_setup(args[2], 0);
    p->threshold = args[3];
    p->rest_ticks = args[4];
    p->heartbeat_ticks = args[5];
    p->required_samples = args[6];
    if (!p->required_samples)
        shutdown("power_monitor requires nonzero confirmation count");
    p->timer.func = power_monitor_event;
    irq_disable();
    p->timer.waketime = timer_read_time() + p->rest_ticks;
    sched_add_timer(&p->timer);
    irq_enable();
}
DECL_COMMAND(command_config_power_monitor,
             "config_power_monitor oid=%c adc_pin=%u int_pin=%u threshold=%hu"
             " rest_ticks=%u heartbeat_ticks=%u required_samples=%c");

void
command_power_monitor_arm(uint32_t *args)
{
    struct power_monitor *p = oid_lookup(
        args[0], command_config_power_monitor);
    if (recovery_valid())
        shutdown("Pending recovery must be handed off before arming");
    const volatile uint16_t *page = (void *)RECOVERY_FLASH_ADDRESS;
    for (uint16_t i=0; i<512; i++)
        if (page[i] != 0xffff)
            shutdown("Recovery page requires MCU reboot before arming");
    p->armed = 1;
}
DECL_COMMAND(command_power_monitor_arm, "power_monitor_arm oid=%c");

// What the monitor last saw - for checking the prototype without a power cut.
void
command_power_monitor_query(uint32_t *args)
{
    uint8_t oid = args[0];
    struct power_monitor *p = oid_lookup(oid, command_config_power_monitor);
    irq_disable();
    uint16_t value = p->last_value;
    uint32_t samples = p->samples;
    uint8_t tripped = p->tripped;
    irq_enable();
    sendf("power_monitor_state oid=%c value=%hu samples=%u tripped=%c"
          , oid, value, samples, tripped);
}
DECL_COMMAND(command_power_monitor_query, "power_monitor_query oid=%c");

void
power_monitor_task(void)
{
    if (!sched_check_wake(&power_monitor_wake))
        return;
    uint8_t oid;
    struct power_monitor *p;
    foreach_oid(oid, p, command_config_power_monitor) {
        if (!p->tripped || p->reported)
            continue;
        p->reported = 1;
        if (recovery_have_sample) {
            irq_disable();
            recovery_saved = recovery_write(&recovery_snapshot);
            irq_enable();
        }
        sendf("power_monitor_tripped oid=%c clock=%u value=%hu"
              , oid, p->trip_clock, p->trip_value);
    }
}
DECL_TASK(power_monitor_task);

// An MCU shutdown clears every timer. Once tripped, the heartbeat is the
// measurement, and losing the host as the power fails is exactly when a
// shutdown is likely - so put it back.
void
power_monitor_shutdown(void)
{
    uint8_t oid;
    struct power_monitor *p;
    foreach_oid(oid, p, command_config_power_monitor) {
        if (!p->tripped)
            continue;
        p->timer.waketime = timer_read_time() + p->heartbeat_ticks;
        sched_add_timer(&p->timer);
    }
}
DECL_SHUTDOWN(power_monitor_shutdown);

// Batches carry four or fewer int16 XYZE samples. Clock/sequence are implicit
// from first_clock, period and first_sequence; this fits the 250kbaud UART.
void
command_recovery_batch(uint32_t *args)
{
    uint32_t clock = args[0], period = args[1], sequence = args[2];
    uint8_t length = args[3];
    const uint8_t *data = command_decode_ptr(args[4]);
    if (!period || length % 8 || length > 32)
        shutdown("Invalid recovery batch");
    irq_disable();
    if (recovery_count + length/8 > RECOVERY_QUEUE) {
        recovery_dropped++;
        irq_enable();
        return;
    }
    for (uint8_t offset=0; offset<length; offset+=8) {
        struct recovery_sample *sample = &recovery_queue[
            (recovery_head + recovery_count) % RECOVERY_QUEUE];
        sample->clock = clock;
        sample->sequence = sequence++;
        int16_t position[4];
        memcpy(position, data+offset, 8);
        for (uint8_t axis=0; axis<4; axis++)
            sample->position[axis] = position[axis];
        recovery_count++;
        clock += period;
    }
    irq_enable();
}
DECL_COMMAND(command_recovery_batch,
             "recovery_batch clock=%u period=%u sequence=%u data=%*s");
void
command_recovery_run(uint32_t *args)
{
    recovery_run = args[0];
    recovery_head = recovery_count = recovery_have_sample = 0;
    recovery_applied = recovery_dropped = 0;
}
DECL_COMMAND(command_recovery_run, "recovery_run run=%u");
void
command_recovery_query(uint32_t *args)
{
    sendf("recovery_record pending=%c saved=%c applied=%u dropped=%u data=%*s",
          recovery_valid(), recovery_saved, recovery_applied, recovery_dropped,
          sizeof(*stored), (void *)stored);
}
DECL_COMMAND_FLAGS(command_recovery_query, HF_IN_SHUTDOWN, "recovery_query");
void
command_recovery_consume(uint32_t *args)
{
    if (!recovery_valid() || stored->run != args[0])
        shutdown("Recovery consume identity mismatch");
    irq_disable();
    flash_unlock();
    uint8_t ok = flash_halfword(RECOVERY_FLASH_ADDRESS
                     + offsetof(struct recovery_record, consumed), 0);
    FLASH->CR = FLASH_CR_LOCK;
    irq_enable();
    if (!ok)
        shutdown("Recovery consume write failed");
}
DECL_COMMAND_FLAGS(command_recovery_consume, HF_IN_SHUTDOWN,
                   "recovery_consume run=%u");
