defmodule EHLS.Device.Generic do
  @moduledoc "The generic device: the default delay model and a 12 ns budget."
  @behaviour EHLS.Device

  @impl true
  def name, do: "generic"

  @impl true
  def budget, do: 12

  @impl true
  def delay_model, do: EHLS.Device.default_model()
end

defmodule EHLS.Device.GowinGW5A do
  @moduledoc """
  Gowin GW5A (Arora V, e.g. the Tang Primer 25K's GW5A-LV25). Besides the compile settings,
  `priv/backend/gowin` has what a build with Gowin's tools uses:

    * `check_timing.py <soc dir>`: reads the timing report and refuses a design that misses
      its constraints or the Fmax margin unless the application accepted it;
    * `gowin_litex.py`: LiteX toolchain settings (`GW_PLACE` / `GW_ROUTE`, the report's
      worst paths, extra SDC lines from modules).
  """
  @behaviour EHLS.Device

  @impl true
  def name, do: "gowin_gw5a"

  # the budget the Tang Primer 25K SoCs (50-60 MHz) are built with: the rest of the clock
  # period is left to the routing
  @impl true
  def budget, do: 12

  @impl true
  def delay_model, do: EHLS.Device.default_model()
end
