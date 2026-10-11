// Experimental STM32F031 recovery storage; not part of release firmware.
#include <stddef.h>
#include <string.h>
#include "autoconf.h"
#include "board/internal.h"
#if !CONFIG_MACH_STM32F031 || CONFIG_FLASH_SIZE != 0x8000 \
    || CONFIG_FLASH_APPLICATION_ADDRESS != 0x08000000
#error Recovery store prototype supports STM32F031 only
#endif
#define RECOVERY_FLASH_ADDRESS 0x08007c00u
#define RECOVERY_MAGIC 0x31524c50u
#define RECOVERY_COMMIT 0xa55au
struct recovery_record {
    uint32_t magic, run, sequence, sample_clock, trip_clock;
    int32_t position[4]; // micrometres, synthetic in the first experiment
    uint32_t crc;
    uint16_t commit, consumed;
};
static const volatile struct recovery_record *stored =
    (void *)RECOVERY_FLASH_ADDRESS;
static uint32_t
recovery_crc(const void *data, uint32_t length)
{
    const uint8_t *p = data;
    uint32_t crc = ~0u;
    while (length--) {
        crc ^= *p++;
        for (uint8_t bit=0; bit<8; bit++)
            crc = (crc >> 1) ^ (0xedb88320u & -(crc & 1));
    }
    return ~crc;
}
static uint8_t
recovery_valid(void)
{
    return stored->magic == RECOVERY_MAGIC
        && stored->commit == RECOVERY_COMMIT && stored->consumed == 0xffff
        && stored->crc == recovery_crc((const void *)stored,
                                      offsetof(struct recovery_record, crc));
}
static void
flash_unlock(void)
{
    if (FLASH->CR & FLASH_CR_LOCK) {
        FLASH->KEYR = 0x45670123;
        FLASH->KEYR = 0xcdef89ab;
    }
    FLASH->SR = FLASH_SR_EOP | FLASH_SR_PGERR | FLASH_SR_WRPERR;
}
static uint8_t
flash_halfword(uint32_t address, uint16_t value)
{
    FLASH->CR = FLASH_CR_PG;
    *(volatile uint16_t *)address = value;
    while (FLASH->SR & FLASH_SR_BSY) { }
    FLASH->CR = 0;
    return !(FLASH->SR & (FLASH_SR_PGERR | FLASH_SR_WRPERR))
        && *(volatile uint16_t *)address == value;
}
void
recovery_init(void)
{
    // Never erase a pending valid record on boot. Erase consumed/torn pages
    // before peripheral timers are configured, while normal power is available.
    if (recovery_valid())
        return;
    const volatile uint16_t *page = (void *)RECOVERY_FLASH_ADDRESS;
    for (uint16_t i=0; i<512; i++) {
        if (page[i] != 0xffff) {
            flash_unlock();
            FLASH->CR = FLASH_CR_PER;
            FLASH->AR = RECOVERY_FLASH_ADDRESS;
            FLASH->CR |= FLASH_CR_STRT;
            while (FLASH->SR & FLASH_SR_BSY) { }
            FLASH->CR = FLASH_CR_LOCK;
            return;
        }
    }
}
DECL_INIT(recovery_init);
static uint8_t
recovery_write(struct recovery_record *r)
{
    r->magic = RECOVERY_MAGIC;
    r->crc = recovery_crc(r, offsetof(struct recovery_record, crc));
    r->commit = RECOVERY_COMMIT;
    r->consumed = 0xffff;
    const uint16_t *half = (const void *)r;
    flash_unlock();
    uint8_t ok = 1;
    // The completion marker is programmed last; consumed stays erased.
    for (uint8_t i=0; i<offsetof(struct recovery_record, consumed)/2; i++) {
        if (!flash_halfword(RECOVERY_FLASH_ADDRESS + i*2, half[i])) {
            ok = 0;
            break;
        }
    }
    FLASH->CR = FLASH_CR_LOCK;
    return ok && recovery_valid();
}
