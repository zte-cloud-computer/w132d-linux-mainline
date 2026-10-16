# SPDX-License-Identifier: MIT
# shellcheck shell=bash
# The public extension search order permits a board-local override. W132D
# supplies checked DDR/BL31 blobs directly and needs no mutable host tools.
[[ "${BOARD}" == w132d ]] || exit_with_error "This rkbin-tools override is for W132D only"
