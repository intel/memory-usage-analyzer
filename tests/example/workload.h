/*
* SPDX-License-Identifier: BSD-3-Clause
* Copyright (c) 2023, Intel Corporation
*/

#include <stdio.h>
#include <stdlib.h>

#define INFO(M, ...) fprintf(stderr, "[INFO] (%s:%d) : " M "\n", __FUNCTION__, __LINE__, ##__VA_ARGS__)
#define WARN(M, ...) fprintf(stderr, "[WARNING] (%s:%d) : " M "\n", __FUNCTION__, __LINE__, ##__VA_ARGS__)
#define ERROR(M, ...) fprintf(stderr, "[ERROR] (%s:%d) : " M "\n", __FUNCTION__, __LINE__, ##__VA_ARGS__)
#define ASSERT(C, M, ...) if (!(C)) { ERROR(M, ##__VA_ARGS__); exit(EXIT_FAILURE); }

const char * fill_data = R"(4ae028a71a25bd21acf70e1eef  lib/modules/4.1.13+/kernel/drivers/media/rc/keymaps/rc-pinnacle-grey.ko
7d59bc6e9b7786b181b16c27b440a945  lib/modules/4.1.13+/kernel/drivers/media/rc/keymaps/rc-pinnacle-pctv-hd.ko
2848904de9593f929691eb095ee0a3ac  lib/modules/4.1.13+/kernel/drivers/media/rc/keymaps/rc-pixelview-002t.ko
4e5fd80b5ec7e261181f17ef903f4600  lib/modules/4.1.13+/kernel/drivers/media/rc/keymaps/rc-pixelview-mk12.ko
c7e443d194607b1abc26422eab8b18db  lib/modules/4.1.13+/kernel/drivers/media/rc/keymaps/rc-pixelview-new.ko
077c553efa76720c6b5a55f7458478dd  lib/modules/4.1.13+/kernel/drivers/media/rc/keymaps/rc-pixelview.ko
a4e53fd7e975228b6ca40c0d9c634eaf  lib/modules/4.1.13+/kernel/drivers/media/rc/keymaps/rc-powercolor-real-angel.ko
78f6c74fe9cc40cd0a9fa97cd45fff6b  lib/modules/4.1.13+/kernel/drivers/media/rc/keymaps/rc-proteus-2309.ko
3215f41e7148aa83ad92f2513ecd2a7d  lib/modules/4.1.13+/kernel/drivers/media/rc/keymaps/rc-purpletv.ko
1f5a38122dc02c07f693691e2b52c264  lib/modules/4.1.13+/kernel/drivers/media/rc/keymaps/rc-pv951.ko
f1ce710764a66ba4306c90eed496ec95  lib/modules/4.1.13+/kernel/drivers/media/rc/keymaps/rc-rc6-mce.ko
8e87dc3ea1ae7bf5d736d04059a51b80  lib/modules/4.1.13+/kernel/drivers/media/rc/keymaps/rc-real-audio-220-32-keys.ko
b197bbc9d4c395063ffceed7ae7f133a  lib/modules/4.1.13+/kernel/drivers/media/rc/keymaps/rc-reddo.ko
fd2959b9327480b4922950b5d6ea1408  lib/modules/4.1.13+/kernel/drivers/media/rc/keymaps/rc-snapstream-firefly.ko
64a23da4f07cdadeab3cc7952b2c0596  lib/modules/4.1.13+/kernel/drivers/media/rc/keymaps/rc-streamzap.ko
cec287d311b4b3cf43170198df2a12af  lib/modules/4.1.13+/kernel/drivers/media/rc/keymaps/rc-su3000.ko
b9b393ad5e2a26f641c8fcf519d8f5f2  lib/modules/4.1.13+/kernel/drivers/media/rc/keymaps/rc-tbs-nec.ko
3d6a9f65b149f1de336f85005804dc26  lib/modules/4.1.13+/kernel/drivers/media/rc/keymaps/rc-technisat-usb2.ko
abfb9ac26ee43c83c5e49017329b73bb  lib/modules/4.1.13+/kernel/drivers/media/rc/keymaps/rc-terratec-cinergy-xs.ko
29e00d140f2e609dc005dc5245992e58  lib/modules/4.1.13+/kernel/drivers/media/rc/keymaps/rc-terratec-slim-2.ko
9e9460c4935cfba5c9a31d8cdba1aecf  lib/modules/4.1.13+/kernel/drivers/media/rc/keymaps/rc-terratec-slim.ko
9ba6317264de68b51f22ba25262bc1b8  lib/modules/4.1.13+/kernel/drivers/media/rc/keymaps/rc-tevii-nec.ko
fb3cb342537ff79560a188b339c549d0  lib/modules/4.1.13+/kernel/drivers/media/rc/keymaps/rc-tivo.ko
7c40c6bc4ebd0f6009e42cabebbc3531  lib/modules/4.1.13+/kernel/drivers/media/rc/keymaps/rc-total-media-in-hand-02.ko
914d3d7ec9a642902306ff8dc5f1addf  lib/modules/4.1.13+/kernel/drivers/media/rc/keymaps/rc-total-media-in-hand.ko
50210237270bfb97777de911d0deffab  lib/modules/4.1.13+/kernel/drivers/media/rc/keymaps/rc-trekstor.ko
cb39a37b4710542540ac37d6129d8ed6  lib/modules/4.1.13+/kernel/drivers/media/rc/keymaps/rc-tt-1500.ko
0358dfc7886fe804987f8c1da24e1132  lib/modules/4.1.13+/kernel/drivers/media/rc/keymaps/rc-twinhan1027.ko
4048558a622e69f5819b967a6c42327d  lib/modules/4.1.13+/kernel/drivers/media/rc/keymaps/rc-videomate-m1f.ko
35b373bf0e23b5e29513e7d3b4f41998  lib/modules/4.1.13+/kernel/drivers/media/rc/keymaps/rc-videomate-s350.ko
4e500ac97ee0a8049aa2bc6074fc8d51  lib/modules/4.1.13+/kernel/drivers/media/rc/keymaps/rc-videomate-tv-pvr.ko
8a4093be07a28643b60d70baf9c90ac4  lib/modules/4.1.13+/kernel/drivers/media/rc/keymaps/rc-winfast-usbii-deluxe.ko
74aac2c987d25436bd0cbcd3931be47c  lib/modules/4.1.13+/kernel/drivers/media/rc/keymaps/rc-winfast.ko
606d11a9ace7c7ad8c99eabe898677ce  lib/modules/4.1.13+/kernel/drivers/media/rc/lirc_dev.ko
1e23f87cdebb920451fc074661a12f6a  lib/modules/4.1.13+/kernel/drivers/media/rc/mceusb.ko
f44c3108eb0aed69db46f9e1f04c2009  lib/modules/4.1.13+/kernel/drivers/media/rc/rc-core.ko
bb1ea8f104ceb3914796a84c37db78c8  lib/modules/4.1.13+/kernel/drivers/media/rc/rc-loopback.ko
4baf5d8c9138a61942a77460c3b0c44d  lib/modules/4.1.13+/kernel/drivers/media/rc/redrat3.ko
b5631aa4d5661093cd362d4e08d04094  lib/modules/4.1.13+/kernel/drivers/media/rc/streamzap.ko
918623c2d54535092e01ec50ea3778f2  lib/modules/4.1.13+/kernel/drivers/media/rc/ttusb)";
