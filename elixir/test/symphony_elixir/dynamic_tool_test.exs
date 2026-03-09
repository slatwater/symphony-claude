defmodule SymphonyElixir.DynamicToolTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Codex.DynamicTool

  test "tool_specs advertises the github_api input contract" do
    specs = DynamicTool.tool_specs()
    assert [tool] = specs
    assert tool["name"] == "github_api"
    assert is_binary(tool["description"])
    assert is_map(tool["inputSchema"])
    assert tool["inputSchema"]["required"] == ["method", "path"]
  end

  test "unsupported tool returns error" do
    response = DynamicTool.execute("nonexistent_tool", %{})
    assert response["success"] == false
  end
end
