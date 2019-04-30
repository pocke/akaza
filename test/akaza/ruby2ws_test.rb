require 'test_helper'

class Ruby2wsTest < Minitest::Test
  # transpile
  def test_transpile_putn
    ws = Akaza::Ruby2ws::Transpiler.new("x = 42; put_as_number x").transpile
    out = StringIO.new
    Akaza.eval(ws, output: out)
    assert_equal "42", out.string
  end

  def test_transpile_putc
    ws = Akaza::Ruby2ws::Transpiler.new("x = 'a'; put_as_char x").transpile
    out = StringIO.new
    Akaza.eval(ws, output: out)
    assert_equal "a", out.string
  end


  # ruby_to_commands

  def test_ruby_to_commands_assign
    commands = Akaza::Ruby2ws::Transpiler.new("x = 1").ruby_to_commands
    assert_equal [
      [:stack, :push, any(Integer)],
      [:stack, :push, 1],
      [:heap, :save],
      [:flow, :exit]
    ], commands
  end

  def test_ruby_to_commands_assign_putn
    commands = Akaza::Ruby2ws::Transpiler.new("x = 1; put_as_number x").ruby_to_commands
    assert_equal [
      [:stack, :push, any(Integer)],
      [:stack, :push, 1],
      [:heap, :save],
      [:stack, :push, any(Integer)],
      [:heap, :load],
      [:io, :write_num],
      [:flow, :exit]
    ], commands
  end

  class AnyClass
    def initialize(klass)
      @klass = klass
    end

    def ==(right)
      right.is_a? @klass
    end
  end

  def any(klass)
    AnyClass.new(klass)
  end
end
