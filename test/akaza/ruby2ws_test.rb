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

  def test_transpile_def_return_value
    assert_eval "42", <<~RUBY
      def foo(x, y)
        x * y
      end

      put_as_number(foo(21, 2))
    RUBY
  end

  def test_transpile_def_return_nil
    assert_eval "4", <<~RUBY
      put_as_number(def foo() 1 end)
    RUBY
  end

  def test_transpile_lvar_to_lvar
    assert_eval "42", <<~RUBY
      x = 42
      y = x
      put_as_number x
    RUBY
  end

  def test_transpile_const
    assert_eval "4242", <<~RUBY
      X = 42

      def foo
        put_as_number X
      end

      foo
      put_as_number X
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

  def test_transpile_if3
    assert_eval "4", <<~RUBY
      put_as_number((42 if 1 == 0)) # It returns nil, and nil is evaluated as 4.
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

  def test_transpile_eqeq
    assert_eval "ft", <<~RUBY
      def check(x, y)
        z = x == y
        if z
          put_as_char 't'
        else
          put_as_char 'f'
        end
      end

      check 1, 2
      check 5, 5
    RUBY
  end

  def test_transpile_spaceship
    assert_eval "-1,0,1", <<~RUBY
      put_as_number 1 <=> 10
      put_as_char ','
      put_as_number 42 <=> 42
      put_as_char ','
      put_as_number 42 <=> 3
    RUBY
  end

  def test_transpile_lt
    assert_eval "12", <<~RUBY
      x = 42
      put_as_number 1 if x < 52
      put_as_number 999 if 52 < x
      put_as_number 2 if -1 < 2
    RUBY
  end

  def test_transpile_gt
    assert_eval "12", <<~RUBY
      x = 42
      put_as_number 1 if x > 32
      put_as_number 999 if 32 > x
      put_as_number 2 if -2 > -5
    RUBY
  end

  def test_transpile_lteq
    assert_eval "123", <<~RUBY
      x = 42
      put_as_number 1 if x <= 52
      put_as_number 999 if 52 <= x
      put_as_number 2 if -10 <= -5
      put_as_number 3 if 3 <= 3
    RUBY
  end

  def test_transpile_gteq
    assert_eval "123", <<~RUBY
      x = 42
      put_as_number 1 if 52 >= x
      put_as_number 999 if x >= 52
      put_as_number 2 if -10 >= -40
      put_as_number 3 if 3 >= 3
    RUBY
  end

  def test_transpile_not
    assert_eval 'ft', <<~RUBY
      if !3
        put_as_char 't'
      else
        put_as_char 'f'
      end

      x = 2
      if !(x == 1)
        put_as_char 't'
      else
        put_as_char 'f'
      end
    RUBY
  end

  def test_transpile_noteq
    assert_eval 'tf', <<~RUBY
      x = 1
      if x != 3
        put_as_char 't'
      else
        put_as_char 'f'
      end

      if x != 1
        put_as_char 't'
      else
        put_as_char 'f'
      end
    RUBY
  end

  def test_transpile_true_false_nil
    assert_eval '123', <<~RUBY
      put_as_number 1 if true
      put_as_number 2 if !false
      put_as_number 3 unless nil
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

  def test_transpile_while
    assert_eval "9876543210", <<~RUBY
      x = 9
      c = 0
      while c == 0
        put_as_number x
        c = 1 if x == 0
        x = x - 1
      end
    RUBY
  end

  def test_transpile_while2
    assert_eval "0123456789", <<~RUBY
      x = -10
      while x < 0
        put_as_number 10 + x
        x = x + 1
      end
    RUBY
  end

  def test_transpile_fizzbuzz
    assert_eval "1 2 fizz 4 buzz fizz 7 8 fizz buzz 11 fizz 13 14 fizzbuzz ", <<~RUBY, StringIO.new("15\n")
      def fizz
        put_as_char 'f'
        put_as_char 'i'
        put_as_char 'z'
        put_as_char 'z'
      end

      def buzz
        put_as_char 'b'
        put_as_char 'u'
        put_as_char 'z'
        put_as_char 'z'
      end

      max = get_as_number
      n = 0 - max
      while n < 0
        x = max + n + 1
        if x % 15 == 0
          fizz
          buzz
        elsif x % 3 == 0
          fizz
        elsif x % 5 == 0
          buzz
        else
          put_as_number x
        end
        put_as_char ' '
        n = n + 1
      end
    RUBY
  end

  def test_transpile_fibo
    assert_eval "1,1,2,3,5,89", <<~RUBY
      def fibo(n)
        if n - 2 < 0
          1
        else
          fibo(n - 1) + fibo(n - 2)
        end
      end

      put_as_number fibo(0)
      put_as_char ','
      put_as_number fibo(1)
      put_as_char ','
      put_as_number fibo(2)
      put_as_char ','
      put_as_number fibo(3)
      put_as_char ','
      put_as_number fibo(4)
      put_as_char ','
      put_as_number fibo(10)
    RUBY
  end

  def test_transpile_array_shift
    assert_eval "123", <<~RUBY
      addr = [1, 2, 3]
      addr2 = addr
      put_as_number addr.shift
      put_as_number addr2.shift
      put_as_number addr.shift
    RUBY
  end

  def test_transpile_array_unshift
    assert_eval "123", <<~RUBY
      addr = [3]
      addr2 = addr
      addr2.unshift 2
      addr.unshift 1

      put_as_number addr.shift
      put_as_number addr.shift
      put_as_number addr.shift
    RUBY
  end

  def test_transpile_unshift_return_value
    assert_eval "123", <<~RUBY
      addr = [3]
      addr2 = addr.unshift 2
      addr.unshift 1

      put_as_number addr.shift
      put_as_number addr.shift
      put_as_number addr2.shift
    RUBY
  end

  def test_transpile_array_def
    assert_eval "123", <<~RUBY
      def shift(array)
        put_as_number array.shift
      end

      array = [1, 2, 3]
      put_as_number array.shift
      shift array
      put_as_number array.shift
    RUBY
  end

  def test_transpile_zarray
    assert_eval "1", <<~RUBY
      x = []
      x.unshift 1
      put_as_number x.shift
    RUBY
  end

  def test_transpile_array_index_access
    assert_eval '321', <<~RUBY
      x = [1, 2, 3]
      put_as_number x[2]
      put_as_number x[1]
      put_as_number x[0]
    RUBY
  end

  def test_transpile_array_index_assign
    assert_eval '5711', <<~RUBY
      x = [1, 2, 3]
      x[0] = 5
      x[1] = 7
      x[2] = 11
      put_as_number x[0]
      put_as_number x[1]
      put_as_number x[2]
    RUBY
  end

  def test_transpile_hash_empty
    assert_eval '', <<~RUBY
      x = {}
    RUBY
  end

  def test_transpile_hash_with_one_value
    assert_eval '', <<~RUBY
      x = {
        1 => 100,
      }
    RUBY
  end

  def test_transpile_hash_with_value
    assert_eval '', <<~RUBY
      x = {
        1 => 2,   # 1 mod 11 = 1
        2 => 3,   # 2 mod 11 = 2
        12 => 4,  # 12 mod 11 = 1
        23 => 10, # 23 mod 11 = 1
      }
    RUBY
  end

  def test_transpile_hash_ref
    assert_eval '42', <<~RUBY
      x = { 1 => 42 }
      put_as_number x[1]
    RUBY
  end

  def test_transpile_hash_ref_with_collision
    assert_eval '42,4,10', <<~RUBY
      x = {
        1 => 42,   # 1 mod 11 = 1
        2 => 3,   # 2 mod 11 = 2
        12 => 4,  # 12 mod 11 = 1
        23 => 10, # 23 mod 11 = 1
      }
      put_as_number x[1]
      put_as_char ','
      put_as_number x[12]
      put_as_char ','
      put_as_number x[23]
    RUBY
  end

  def test_transpile_hash_nested
    assert_eval '2,5', <<~RUBY
      x = {
        1 => 2,
        3 => {
          4 => 5,
        },
      }
      put_as_number x[1]
      put_as_char ','
      put_as_number x[3][4]
    RUBY
  end

  def assert_eval(expected_output, code, input = StringIO.new(''))
    ws = Akaza::Ruby2ws::Transpiler.new(code).transpile
    out = StringIO.new
    Akaza.eval(ws, input: input, output: out)
    assert_equal expected_output, out.string
  end
end
