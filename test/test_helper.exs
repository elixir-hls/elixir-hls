# The instances in these tests are circuits unless a test says otherwise (EHLS.placement/0 is :cpu with no backend)
if System.get_env("EHLS_PLACEMENT") in [nil, ""], do: System.put_env("EHLS_PLACEMENT", "fpga")
# The :circt tests run CIRCT and iverilog on every case (minutes): EHLS_TEST_CIRCT=1 mix test
exclude = if System.get_env("EHLS_TEST_CIRCT") in ["1", "true"], do: [], else: [:circt]
ExUnit.start(exclude: exclude)
