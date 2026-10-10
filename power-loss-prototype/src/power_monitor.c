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

struct power_monitor {
    struct timer timer;
    uint32_t rest_ticks, heartbeat_ticks, trip_clock;
    struct gpio_adc adc;
    struct gpio_out out;
    uint16_t threshold, trip_value, last_value;
    uint32_t samples;
    uint8_t tripped, reported, level;
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
    uint32_t sample_delay = gpio_adc_sample(p->adc);
    if (sample_delay) {
        p->timer.waketime = timer_read_time() + sample_delay;
        return SF_RESCHEDULE;
    }
    uint16_t value = gpio_adc_read(p->adc);
    p->last_value = value;
    p->samples++;
    if (value < p->threshold) {
        p->tripped = 1;
        p->level = 1;
        gpio_out_write(p->out, 1);
        p->trip_clock = timer_read_time();
        p->trip_value = value;
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
    p->timer.func = power_monitor_event;
    irq_disable();
    p->timer.waketime = timer_read_time() + p->rest_ticks;
    sched_add_timer(&p->timer);
    irq_enable();
}
DECL_COMMAND(command_config_power_monitor,
             "config_power_monitor oid=%c adc_pin=%u int_pin=%u threshold=%hu"
             " rest_ticks=%u heartbeat_ticks=%u");

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
