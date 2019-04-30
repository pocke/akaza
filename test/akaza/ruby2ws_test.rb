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

  def test_transpile_def_args
    assert_eval "42", <<~RUBY
      def foo(x, y)
        put_as_number x
        put_as_number y
      end

      foo 4, 2
    RUBY
  end

  def test_transpile_lvar_to_lvar
    assert_eval "42", <<~RUBY
      x = 42
      y = x
      put_as_number x
    RUBY
  end

  def test_transpile_if
    assert_eval "42", <<~RUBY
      x = 0
      if x == 0
        put_as_number 42
      else
        put_as_number 24
      end
    RUBY
  end

  def test_transpile_if2
    assert_eval "42", <<~RUBY
      x = 0
      if x == 0
        put_as_number 42
      end
    RUBY
  end

  def test_transpile_unless
    assert_eval "42", <<~RUBY
      x = 1
      unless x == 0
        put_as_number 42
      end
    RUBY
  end

  def test_transpile_if_neg
    assert_eval "42", <<~RUBY
      x = 1
      if x < 0
        put_as_number 1
      else
        put_as_number 42
      end
    RUBY
  end

  def test_transpile_read_char
    assert_eval "rab", <<~RUBY, StringIO.new("bar")
      x = get_as_char
      y = get_as_char
      z = get_as_char
      put_as_char z
      put_as_char y
      put_as_char x
    RUBY
  end

  def test_transpile_read_num
    assert_eval "2442", <<~RUBY, StringIO.new("42\n24")
      x = get_as_number
      y = get_as_number
      put_as_number y
      put_as_number x
    RUBY
  end

  def test_transpile_exit
    assert_eval "42", <<~RUBY, StringIO.new("42\n24")
      put_as_number 42
      exit
      put_as_number 42
    RUBY
  end

  def test_transpile_add
    assert_eval "5", <<~RUBY
      put_as_number 3 + 2
    RUBY
  end

  def test_transpile_sub
    assert_eval "95", <<~RUBY
      put_as_number 100 - 5
    RUBY
  end

  def test_transpile_multi
    assert_eval "24", <<~RUBY
      put_as_number 3 * 8
    RUBY
  end

  def test_transpile_div
    assert_eval "2", <<~RUBY
      put_as_number 4 / 2
    RUBY
  end

  def test_transpile_mod
    assert_eval "1", <<~RUBY
      put_as_number 10 % 3
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

  def assert_eval(expected_output, code, input = StringIO.new(''))
    ws = Akaza::Ruby2ws::Transpiler.new(code).transpile
    out = StringIO.new
    Akaza.eval(ws, input: input, output: out)
    assert_equal expected_output, out.string
  end
end
