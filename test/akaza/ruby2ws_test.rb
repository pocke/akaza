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

  def test_transpile_raise
    assert_eval "x(eval):2:0: Foobar (Error)\n", <<~RUBY
      put_as_char 'x'
      raise "Foobar"
      put_as_char 'y'
    RUBY
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

  def test_transpile_def_lvar3
    # with uninitialized lvar
    assert_eval "5", <<~RUBY
      def foo
        50
      end

      def bar
        a = 3
        if a == 3
          foo
          put_as_number 5
        else
          x = 6
          put_as_number x
        end
      end

      bar
    RUBY
  end

  def test_transpile_lvar_if_false
    # nil is 4
    assert_eval "4", <<~RUBY
      x = 100 if false
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

  def test_transpile_class
    assert_eval "40,42", <<~RUBY
      class Array
        def ps(x)
          self.push(x)
        end
      end

      class Integer
        def wrap_array
          [self]
        end
      end

      x = []
      x.ps(40)
      put_as_number x[0]

      put_as_char ','

      a = 42.wrap_array
      put_as_number a[0]
    RUBY
  end

  def test_transpile_class_fcall_1
    assert_eval "40", <<~RUBY
      class Array
        def ps(x)
          self.push(x)
        end

        def ps2(x)
          ps(x)
        end
      end

      x = []
      x.ps2(40)
      put_as_number x[0]
    RUBY
  end

  def test_transpile_class_fcall_pop
    assert_eval "40", <<~RUBY
      class Array
        def pop2
          pop
        end
      end

      x = [40]
      put_as_number x.pop2
    RUBY
  end

  def test_transpile_class_fcall_push
    assert_eval "40", <<~RUBY
      class Array
        def push2(x)
          push(x)
        end
      end

      x = []
      x.push2(40)
      put_as_number x[0]
    RUBY
  end

  def test_transpile_class_fcall_array_ref
    assert_eval "y", <<~RUBY
      class Array
        def fetch(key)
          self[key]
        end
      end

      array = ['x', 'y', 'z']
      put_as_char array.fetch(1)
    RUBY
  end

  def test_transpile_class_fcall_hash_ref
    assert_eval "20", <<~RUBY
      class Hash
        def fetch(key)
          self[key]
        end
      end

      hash = { 1 => 20, 3 => 40 }
      put_as_number hash.fetch(1)
    RUBY
  end

  def test_transpile_class_error
    assert_eval "(eval):1:0: Unknown type of receiver (Error)\n", <<~RUBY
      nil.unknown_method
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

  def test_transpile_case
    assert_eval "42", <<~RUBY
      x = 1
      case x
      when 2
        put_as_number 44
      when 1
        put_as_number 42
      end
    RUBY
  end

  def test_transpile_case2
    assert_eval "42", <<~RUBY
      x = 1
      case x
      when 2, 3
        put_as_number 44
      when 5, 4, 1
        put_as_number 42
      end
    RUBY
  end

  def test_transpile_case2
    assert_eval "42", <<~RUBY
      x = 1
      case x
      when 1
        put_as_number 42
      when 5, 4, 1
        put_as_number 44
      end
    RUBY
  end

  def test_transpile_case_retval
    assert_eval "42", <<~RUBY
      x = 1
      v =
        case x
        when 1
          42
        when 5, 4, 1
          100
        end
      put_as_number v
    RUBY
  end

  def test_transpile_case_retval2
    assert_eval "42", <<~RUBY
      x = 1
      v =
        case x
        when 100
          444
        when 5, 4, 1000
          100
        end
      put_as_number 42 if v == nil
    RUBY
  end

  def test_transpile_case_else
    assert_eval "42", <<~RUBY
      x = 42
      v =
        case x
        when 100
          444
        when 5, 4, 1000
          100
        else
          x
        end
      put_as_number v
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

  def test_transpile_while3
    assert_eval "42", <<~RUBY
      flag = true
      while flag
        put_as_number 42
        flag = false
      end
    RUBY
  end

  def test_transpile_while_retval
    # while returns nil, and nil will be 4.
    assert_eval "4,4,4", <<~RUBY
      put_as_number(while false
        100
      end)
      put_as_char ','

      flag = true
      put_as_number(while flag
        flag = false
        100
      end)
      put_as_char ','

      n = 0
      put_as_number(while n == 0
        n = 1
        100
      end)
    RUBY
  end

  def test_transpile_while_true
    assert_eval '42', <<~RUBY
      while true
        put_as_number 42
        exit
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
        if n < 2
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

  def test_transpile_array_pop
    assert_eval "321", <<~RUBY
      addr = [1, 2, 3]
      addr2 = addr
      put_as_number addr.pop
      put_as_number addr2.pop
      put_as_number addr.pop
    RUBY
  end

  def test_transpile_array_pop_when_empty
    assert_eval "21o", <<~RUBY
      addr = [1, 2]
      addr2 = addr
      put_as_number addr.pop
      put_as_number addr2.pop
      put_as_char 'o' if addr.pop == nil
    RUBY
  end

  def test_transpile_array_pop_size
    assert_eval "221100", <<~RUBY
      arr = [1, 2, 3]
      arr2 = arr

      arr.pop
      put_as_number arr.size
      put_as_number arr2.size
      arr2.pop
      put_as_number arr.size
      put_as_number arr2.size
      arr.pop
      put_as_number arr.size
      put_as_number arr2.size
    RUBY
  end

  def test_transpile_array_push_size
    assert_eval "112233", <<~RUBY
      arr = []
      arr2 = arr

      arr.push 1
      put_as_number arr.size
      put_as_number arr2.size
      arr2.push 5
      put_as_number arr.size
      put_as_number arr2.size
      arr.push 30
      put_as_number arr.size
      put_as_number arr2.size
    RUBY
  end

  def test_transpile_array_size
    assert_eval '0,1,5', <<~RUBY
      x = []
      put_as_number x.size
      put_as_char ','

      y = [42]
      put_as_number y.size
      put_as_char ','

      z = [2, 3, 5, 7, 11]
      put_as_number z.size
    RUBY
  end

  def test_transpile_array_push
    assert_eval "123", <<~RUBY
      addr = [3]
      addr2 = addr
      addr2.push 2
      addr.push 1

      put_as_number addr.pop
      put_as_number addr.pop
      put_as_number addr.pop
    RUBY
  end

  def test_transpile_push_return_value
    assert_eval "123", <<~RUBY
      addr = [3]
      addr2 = addr.push 2
      addr.push 1

      put_as_number addr.pop
      put_as_number addr.pop
      put_as_number addr2.pop
    RUBY
  end

  def test_transpile_array_def
    assert_eval "321", <<~RUBY
      def pop(array)
        put_as_number array.pop
      end

      array = [1, 2, 3]
      put_as_number array.pop
      pop array
      put_as_number array.pop
    RUBY
  end

  def test_transpile_zarray
    assert_eval "1", <<~RUBY
      x = []
      x.push 1
      put_as_number x.pop
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

  def test_transpile_array_long_lit
    assert_eval '4,12', <<~RUBY
      x = [1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15]
      put_as_number x[3]
      put_as_char ','
      put_as_number x[11]
    RUBY
  end

  def test_transpile_array_realloc_1
    assert_eval '6,38,20', <<~RUBY
      x = []
      i = 0
      while i < 20
        x.push i * 2
        i = i + 1
      end
      put_as_number x[3]
      put_as_char ','
      put_as_number x[19]
      put_as_char ','
      put_as_number x.size
    RUBY
  end

  def test_transpile_array_realloc_2
    assert_eval '6,38,30', <<~RUBY
      x = []
      i = 0
      while i < 30
        x.push i * 2
        i = i + 1
      end
      put_as_number x[3]
      put_as_char ','
      put_as_number x[19]
      put_as_char ','
      put_as_number x.size
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

  def test_transpile_hash_ref_nil
    assert_eval 'oo', <<~RUBY
      x = { 1 => 42 }
      put_as_char 'o' if x[2] == nil # not collision
      put_as_char 'o' if x[12] == nil # collision
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

  def test_transpile_hash_attr_asgn_to_existing
    assert_eval '32,55,100,-4', <<~RUBY
      x = {
        1 => 42,   # 1 mod 11 = 1
        2 => 3,   # 2 mod 11 = 2
        12 => 8,  # 12 mod 11 = 1
        23 => 10, # 23 mod 11 = 1
      }
      x[1] = 32
      x[2] = 55
      x[12] = 100
      x[23] = -4
      put_as_number x[1]
      put_as_char ','
      put_as_number x[2]
      put_as_char ','
      put_as_number x[12]
      put_as_char ','
      put_as_number x[23]
    RUBY
  end

  def test_transpile_hash_attr_asgn_to_not_existing_key
    assert_eval '32,55,100,-4', <<~RUBY
      x = {}

      x[1] = 32
      x[2] = 55
      x[12] = 100
      x[23] = -4
      put_as_number x[1]
      put_as_char ','
      put_as_number x[2]
      put_as_char ','
      put_as_number x[12]
      put_as_char ','
      put_as_number x[23]
    RUBY
  end

  def test_transpile_prelude_array_first
    assert_eval '3', <<~RUBY
      x = [3, 2, 1]
      put_as_number x.first
    RUBY
  end

  def test_transpile_prelude_array_empty_p
    assert_eval '45', <<~RUBY
      x = []
      put_as_number 4 if x.empty?
      y = [1]
      put_as_number 5 unless y.empty?
    RUBY
  end

  def test_transpile_if_retval
    assert_eval "11,23,22,33", <<~RUBY
      def check(x, y)
        if x == 1
          [11]
        elsif x == 2
          if y == 3
            [23]
          else
            [22]
          end
        else
          [33]
        end
      end

      put_as_number check(1, -1)[0]
      put_as_char ','
      put_as_number check(2, 3)[0]
      put_as_char ','
      put_as_number check(2, 4)[0]
      put_as_char ','
      put_as_number check(3, 4)[0]
    RUBY
  end

  def test_transpile_call_var
    assert_eval "42", <<~RUBY
      def foo
        x = 1
        bar
        y = 1
      end

      def bar
        put_as_number 42
      end

      foo
    RUBY
  end

  def test_transpile_call_array_nested
    assert_eval "3,3,1,42,6,2,3,5", <<~RUBY
      a = [
        [6, 2, 3],
        42,
        [5],
      ]
      put_as_number a.size
      put_as_char ','
      put_as_number a[0].size
      put_as_char ','
      put_as_number a[2].size
      put_as_char ','
      put_as_number a[1]
      put_as_char ','
      put_as_number a[0][0]
      put_as_char ','
      put_as_number a[0][1]
      put_as_char ','
      put_as_number a[0][2]
      put_as_char ','
      put_as_number a[2][0]
    RUBY
  end

  def test_transpile_array_2
    assert_eval '123', <<~RUBY
      c = [1, 123]
      s = []
      s.push c[1]
      put_as_number s[0]
    RUBY
  end

  def test_transpile_compare
    # true: 2, false: 0
    assert_eval "0,2,0,2,0,2", <<~RUBY
      put_as_number(4 == nil)
      put_as_char ','
      put_as_number(nil == nil)
      put_as_char ','
      put_as_number(0 == false)
      put_as_char ','
      put_as_number(false == false)
      put_as_char ','
      put_as_number(2 == true)
      put_as_char ','
      put_as_number(true == true)
    RUBY
  end

  def test_transpile_is_a
    assert_eval "111", <<~RUBY
      x = []
      put_as_number 1 if x.is_a?(Array)
      put_as_number 999 if x.is_a?(Integer)
      x = 1
      put_as_number 1 if x.is_a?(Integer)
      put_as_number 999 if x.is_a?(Hash)
      x = {}
      put_as_number 1 if x.is_a?(Hash)
      put_as_number 999 if x.is_a?(Integer)
    RUBY
  end

  def assert_eval(expected_output, code, input = StringIO.new(''))
    ws = Akaza::Ruby2ws.ruby_to_ws(code)
    out = StringIO.new
    Akaza.eval(ws, input: input, output: out)
    assert_equal expected_output, out.string
  end
end
