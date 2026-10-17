# ccflags-y += -DDEBUG
# ccflags-y += -DKERNEL_VERSION_414
ccflags-y += -I$(srctree)/drivers/net/wireless/uwe5621ds/unisocwcn/include
ccflags-y += -DOTT_UWE
ccflags-y += -DWOBLE_FUN

ifneq ($(UNISOC_BSP_INCLUDE),)
ccflags-y += -I$(UNISOC_BSP_INCLUDE)
endif

sprdbt_tty-y := \
	tty.o \
	rfkill.o \
	lpm.o \
	woble.o\
	alignment/sitm.o \
	dump.o

sprdbt_tty-$(CONFIG_TTY_OVERY_SDIO_HCI) += hci.o

obj-$(CONFIG_TTY_OVERY_SDIO) += sprdbt_tty.o

