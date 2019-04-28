require 'test_helper'

class AkazaTest < Minitest::Test
  def test_eval_hello_world
    code = File.read(File.expand_path("./fixtures/hello.ws", __dir__))
    input = StringIO.new
    output = StringIO.new
    Akaza.eval(code, input: input, output: output)
    assert_equal "Hello, world of spaces!\r\n", output.string
  end

  def test_eval_sum
    code = File.read(File.expand_path("./fixtures/sum.ws", __dir__))
    input = StringIO.new("20\n22\n")
    output = StringIO.new
    Akaza.eval(code, input: input, output: output)
    assert_equal "42", output.string
  end
end
