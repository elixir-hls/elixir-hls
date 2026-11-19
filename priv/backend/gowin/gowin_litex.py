"""
elixir-hls' Gowin device backend (EHLS.Device.GowinGW5A) for a LiteX build with Gowin's
tools:

    import gowin_litex          # on import: modules may add SDC lines (platform.extra_sdc)
    gowin_litex.setup(soc)      # after the SoC is built up

  * platform.extra_sdc: raw SDC lines a module appends (e.g. a USB host's ULPI pad delays),
    written after LiteX's own constraints;
  * GW_PLACE / GW_ROUTE (environment): Gowin's place_option / route_option, set only when
    given (the tools' defaults otherwise);
  * the worst setup and hold paths of the whole design in the timing report, which
    check_timing.py reads.
"""
from litex.build.generic_platform import Misc
import os

from litex.build.gowin.gowin import GowinToolchain

_orig_build_timing_constraints = GowinToolchain.build_timing_constraints


def _build_timing_constraints(self, vns):
    name, kind = _orig_build_timing_constraints(self, vns)
    extra = getattr(self.platform, "extra_sdc", [])
    if extra:
        with open(name, "a") as f:
            f.write("\n" + "\n".join(extra) + "\n")
    return name, kind


GowinToolchain.build_timing_constraints = _build_timing_constraints


def setup(soc):
    for env, opt in (("GW_PLACE", "place_option"), ("GW_ROUTE", "route_option")):
        if env in os.environ:
            soc.platform.toolchain.options[opt] = int(os.environ[env])
    # check_timing.py reads every path table: the whole design's worst setup and hold paths
    # must be in the report (project_tr_content.html)
    soc.platform.extra_sdc = getattr(soc.platform, "extra_sdc", []) + [
        "report_timing -setup -max_paths 30", "report_timing -hold -max_paths 30"]


def pin_pull(pull):
    """The pin constraints for a pull (up, down, none): hls_litex.add_hls's pin_pull."""
    return [Misc(f"PULL_MODE={pull.upper()}")]
