require 'minitest'
require 'minitest/autorun'

require 'akaza'

module AkazaTestHelper
  def assert_eval(expected_output, code, input = StringIO.new(''))
    out = StringIO.new
    ws = Akaza::Ruby2ws.ruby_to_ws(code)
    Akaza.eval(ws, input: input, output: out)
    assert_equal expected_output, out.string
  rescue => ex
    puts "out: #{out.string.inspect}"
    raise ex
  end
end

Minitest::Test.include AkazaTestHelper
