obj-m += intel_skl_int3472_tps68470.o ipu-bridge.o ov8858.o intel-lpss-acpi.o leds-tps68470.o
intel_skl_int3472_tps68470-y := tps68470.o tps68470_board_data.o

KDIR ?= /lib/modules/$(shell uname -r)/build

all:
	$(MAKE) -C $(KDIR) M=$(CURDIR) modules

clean:
	$(MAKE) -C $(KDIR) M=$(CURDIR) clean
