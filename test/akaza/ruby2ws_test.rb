require 'test_helper'

class Ruby2wsTest < Minitest::Test
  # transpile
  def test_transpile_putn
    assert_eval "42", "x = 42; put_as_number x"
  end

  def test_transpile_putc
    assert_eval "a", "x = 'a'; put_as_char x"
  end

  def test_transpile_putn_literal
    assert_eval "42", "put_as_number 42"
  end

  def test_transpile_putc_literal
    assert_eval "a", "put_as_char 'a'"
  end

  def test_transpile_def
    assert_eval "42", "def put_42() put_as_number(42) end; put_42"
  end

  def test_transpile_def_lvar1
    assert_eval "42", <<~RUBY
      x = 2

      def foo
        put_as_number 4
      end

      foo
      put_as_number x
    RUBY
  end

  def test_transpile_def_lvar2
    assert_eval "42", <<~RUBY
      x = 2

      def foo
        x = 100
        bar
      end

      def bar
        x = 4
        put_as_number x
      end

      foo
      put_as_number x
    RUBY
  end

  def test_transpile_lvar_to_lvar
    assert_eval "42", <<~RUBY
      x = 42
      y = x
      put_as_number x
    RUBY
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

  def assert_eval(expected_output, code)
    ws = Akaza::Ruby2ws::Transpiler.new(code).transpile
    out = StringIO.new
    Akaza.eval(ws, output: out)
    assert_equal expected_output, out.string
  end
end
