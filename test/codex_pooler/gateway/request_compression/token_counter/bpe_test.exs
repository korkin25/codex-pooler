defmodule CodexPooler.Gateway.RequestCompression.TokenCounter.BPETest do
  use ExUnit.Case, async: true
  alias CodexPooler.Gateway.RequestCompression.TokenCounter.BPE

  test "empty, single-byte and whole-token inputs preserve token identities" do
    ranks = %{"a" => 0, "b" => 1, "ab" => 2}
    assert BPE.count("", ranks) == 0
    assert BPE.encode("", ranks) == []
    assert BPE.encode("a", ranks) == [0]
    assert BPE.encode("ab", ranks) == [2]
    assert BPE.count("x", ranks) == 1
  end

  test "pair rank decides the merge and equal ranks preserve the leftmost pair" do
    base = %{"a" => 10, "b" => 11, "c" => 12, "d" => 13}
    assert BPE.encode("abcd", base) == [10, 11, 12, 13]
    assert BPE.encode("abc", Map.merge(base, %{"ab" => 1, "bc" => 0})) == [10, 0]
    assert BPE.encode("abc", Map.merge(base, %{"ab" => 0, "bc" => 0})) == [0, 12]
    assert BPE.encode("abc", Map.put(base, "bc", 0)) == [10, 0]
  end
end
