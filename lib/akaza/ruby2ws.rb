module Akaza
  # Convert Ruby like script to Whitespace.
  # The syntax is a subset of Ruby,
  # but it has different semantics with Ruby.
  #
  # # sample code
  #   # output
  #   put_as_number n
  #   put_as_char ch
  #   put_as_number 42
  #   put_as_char 'a'
  #
  #   # input
  #   num = get_as_number
  #   char = get_as_char
  #
  #   # flow
  #   def foo
  #   end
  #
  #   exit
  #
  #   if x == 0
  #   end
  #
  #   if x < 0
  #   end
  #
  #   # heap
  #   x = 10
  #   push x
  module Ruby2ws
    using AstExt

    SPACE = ' '
    TAB = "\t"
    NL = "\n"

    NONE_ADDR = 0
    TMP_ADDR = 1

    TYPE_BITS = 2

    TYPE_SPECIAL = 0b00
    TYPE_INT     = 0b01
    TYPE_ARRAY   = 0b10
    TYPE_HASH    = 0b11

    HASH_SIZE = 11

    # NIL is nil
    NIL = 0 << TYPE_BITS + TYPE_SPECIAL
    # NONE is for internal. It does not available for user.
    NONE = 1 << TYPE_BITS + TYPE_SPECIAL

    # Call when stack top is the target number.
    UNWRAP_COMMANDS = [
      [:stack, :push, 2 ** TYPE_BITS],
      [:calc, :div],
    ].freeze
    WRAP_NUMBER_COMMANDS = [
      [:stack, :push, 2 ** TYPE_BITS],
      [:calc, :multi],
      [:stack, :push, TYPE_INT],
      [:calc, :add],
    ].freeze
    WRAP_ARRAY_COMMANDS = [
      [:stack, :push, 2 ** TYPE_BITS],
      [:calc, :multi],
      [:stack, :push, TYPE_ARRAY],
      [:calc, :add],
    ].freeze
    SAVE_TMP_COMMANDS = [
      [:stack, :dup],
      [:stack, :push, TMP_ADDR],
      [:stack, :swap],
      [:heap, :save],
    ]
    LOAD_TMP_COMMANDS = [
      [:stack, :push, TMP_ADDR],
      [:heap, :load],
    ]

    class ParseError < StandardError; end

    def self.ruby_to_ws(ruby_code)
      Transpiler.new(ruby_code).transpile
    end

    class Transpiler
      def initialize(ruby_code)
        @ruby_code = ruby_code

        @addr_index = 1
        @addrs = {}

        @label_index = 0
        @labels = {}

        @methods = []
        @lvars_stack = [[]]
      end

      def transpile
        ast = RubyVM::AbstractSyntaxTree.parse(@ruby_code)
        commands = compile_expr(ast)
        commands << [:flow, :exit]
        commands.concat(*@methods)
        commands_to_ws(commands)
      end

      private def compile_expr(node)
        commands = []

        case node
        in [:FCALL, :put_as_number, [:ARRAY, arg, nil]]
          commands.concat(compile_expr(arg))
          commands.concat(UNWRAP_COMMANDS)
          commands << [:io, :write_num]
          commands << [:stack, :push, NIL]
        in [:FCALL, :put_as_char, [:ARRAY, arg, nil]]
          commands.concat(compile_expr(arg))
          commands.concat(UNWRAP_COMMANDS)
          commands << [:io, :write_char]
          commands << [:stack, :push, NIL]
        in [:VCALL, :get_as_number]
          commands << [:stack, :push, TMP_ADDR]
          commands << [:io, :read_num]
          commands << [:stack, :push, TMP_ADDR]
          commands << [:heap, :load]
          commands.concat(WRAP_NUMBER_COMMANDS)
        in [:VCALL, :get_as_char]
          commands << [:stack, :push, TMP_ADDR]
          commands << [:io, :read_char]
          commands << [:stack, :push, TMP_ADDR]
          commands << [:heap, :load]
          commands.concat(WRAP_NUMBER_COMMANDS)
        in [:OPCALL, l, sym, [:ARRAY, r, nil]]
          com = {'+': :add, '-': :sub, '*': :multi, '/': :div, '%': :mod}[sym]
          raise ParserError, "Unknown symbol: #{sym}" unless com
          commands.concat(compile_expr(l))
          commands.concat(UNWRAP_COMMANDS)
          commands.concat(compile_expr(r))
          commands.concat(UNWRAP_COMMANDS)
          commands << [:calc, com]
          commands.concat(WRAP_NUMBER_COMMANDS)
        in [:CALL, expr, :shift, nil]
          commands.concat(compile_expr(expr))
          commands.concat(UNWRAP_COMMANDS)
          # stack: [unwrapped_addr_of_array]

          commands << [:stack, :dup]
          commands << [:heap, :load]
          # stack: [unwrapped_addr_of_array, addr_of_first_item]
          commands << [:stack, :swap]
          commands << [:stack, :dup]
          commands << [:heap, :load]
          # stack: [addr_of_first_item, unwrapped_addr_of_array, addr_of_first_item]

          commands << [:stack, :push, 1]
          commands << [:calc, :add]
          commands << [:heap, :load]
          # stack: [addr_of_first_item, unwrapped_addr_of_array, addr_of_second_item]

          commands << [:heap, :save]
          # stack: [addr_of_first_item]

          commands << [:heap, :load]
          # stack: [first_item]
        in [:CALL, recv, :[], [:ARRAY, index, nil]]
          label_array = ident_to_label(nil)
          label_end = ident_to_label(nil)

          commands.concat(compile_expr(recv))
          commands << [:stack, :dup]
          commands << [:stack, :push, 2 ** TYPE_BITS]
          commands << [:calc, :mod]
          commands << [:stack, :push, TYPE_ARRAY]
          commands << [:calc, :sub]
          commands << [:flow, :jump_if_zero, label_array] # when array

          # when hash
          commands.concat(compile_expr(index))
          commands << [:flow, :call, hash_index_access_label]
          commands << [:flow, :jump, label_end]

          # when array
          commands << [:flow, :def, label_array]
          commands.concat(compile_expr(index))
          commands << [:flow, :call, array_index_access_label]

          commands << [:flow, :def, label_end]
        in [:VCALL, :exit]
          commands << [:flow, :exit]
        in [:LASGN, var, arg]
          commands.concat(compile_expr(arg))
          commands << [:stack, :dup]
          var_addr = ident_to_addr(var)
          commands << [:stack, :push, var_addr]
          commands << [:stack, :swap]
          commands << [:heap, :save]
          lvars << var_addr
        in [:ATTRASGN, recv, :[]=, [:ARRAY, index, value, nil]]
          commands.concat(compile_expr(recv))
          commands.concat(UNWRAP_COMMANDS)
          commands << [:heap, :load]
          commands.concat(compile_expr(index))
          # stack: [addr_of_first_item, index]

          commands.concat(UNWRAP_COMMANDS)
          commands.concat(times do
            c = []
            c << [:stack, :swap]
            # stack: [index, addr_of_first_item]
            c << [:stack, :push, 1]
            c << [:calc, :add]
            c << [:heap, :load]
            # stack: [index, addr_of_next_item]
            c << [:stack, :swap]
            c
          end)
          commands << [:stack, :pop] # pop index
          commands << [:stack, :dup]
          # stack: [addr_of_the_target_item, addr_of_the_target_item]

          commands.concat(compile_expr(value))
          commands << [:heap, :save]
          # stack: [addr_of_the_target_item]
          commands << [:heap, :load]
        in [:DEFN, name, [:SCOPE, lvar_table, [:ARGS, args_count ,*_], body]]
          m = [
            [:flow, :def, ident_to_label(name)],
          ]
          lvar_table[0...args_count].reverse.each do |args_name|
            m << [:stack, :push, ident_to_addr(args_name)]
            m << [:stack, :swap]
            m << [:heap, :save]
          end
          @lvars_stack << []
          m.concat(compile_expr(body))
          @lvars_stack.pop
          m << [:flow, :end]

          @methods << m
        in [:SCOPE, _, _, body]
          commands.concat(compile_expr(body))
        in [:BLOCK, *children]
          children.each.with_index do |child, index|
            commands.concat(compile_expr(child))
            commands << [:stack, :pop] unless index == children.size - 1
          end
        in [:VCALL, name]
          commands.concat(compile_call(name, []))
        in [:FCALL, name, [:ARRAY, *args, nil]]
          commands.concat(compile_call(name, args))
        in [:CALL, recv, :unshift, [:ARRAY, expr, nil]]
          commands.concat(compile_expr(recv))
          commands << [:stack, :dup]
          commands.concat(UNWRAP_COMMANDS)
          # stack: [array, unwrapped_addr_of_array]

          commands << [:stack, :dup]
          commands << [:heap, :load]
          # stack: [array, unwrapped_addr_of_array, addr_of_first_item]

          # Allocate a new item
          new_item_value_addr = next_addr_index
          new_item_addr_addr = next_addr_index
          commands << [:stack, :push, new_item_value_addr]
          commands.concat(compile_expr(expr))
          commands << [:heap, :save]
          commands << [:stack, :push, new_item_addr_addr]
          commands << [:stack, :swap]
          commands << [:heap, :save]
          # stack: [array, unwrapped_addr_of_array]

          commands << [:stack, :push, new_item_value_addr]
          commands << [:heap, :save]
        in [:IF, cond, if_body, else_body]
          commands.concat(compile_if(cond, if_body, else_body))
        in [:UNLESS, cond, else_body, if_body]
          commands.concat(compile_if(cond, if_body, else_body))
        in [:WHILE, cond, body]
          commands.concat(compile_while(cond, body))
        in [:LIT, num]
          commands << [:stack, :push, with_type(num, TYPE_INT)]
        in [:STR, str]
          check_char!(str)
          commands << [:stack, :push, with_type(str.ord, TYPE_INT)]
        in [:LVAR, name]
          commands << [:stack, :push, ident_to_addr(name)]
          commands << [:heap, :load]
        in [:ARRAY, *items, nil]
          array_addr = next_addr_index
          addrs = ((items.size) * 2).times.map { next_addr_index }
          commands << [:stack, :push, array_addr]
          commands << [:stack, :push, addrs[0] || NONE_ADDR]
          commands << [:heap, :save]

          items.each.with_index do |item, index|
            value_addr = addrs[index * 2]
            commands << [:stack, :push, value_addr]
            commands.concat(compile_expr(item))
            commands << [:heap, :save]

            next_addr = addrs[index * 2 + 1]
            val = addrs[(index + 1) * 2] || NONE_ADDR
            commands << [:stack, :push, next_addr]
            commands << [:stack, :push, val]
            commands << [:heap, :save]
          end

          commands << [:stack, :push, with_type(array_addr, TYPE_ARRAY)]
        in [:ZARRAY]
          addr = next_addr_index
          commands << [:stack, :push, addr]
          commands << [:stack, :push, NONE_ADDR]
          commands << [:heap, :save]
          commands << [:stack, :push, with_type(addr, TYPE_ARRAY)]
        in [:HASH, nil]
          hash_addr = next_addr_index
          commands.concat(initialize_hash(hash_addr))
        in [:HASH, [:ARRAY, *pairs, nil]]
          hash_addr = next_addr_index
          # initialize_hash sets the return value to bottom of the stack.
          commands.concat(initialize_hash(hash_addr))

          no_collision_label = ident_to_label(nil)
          when_collision_label = ident_to_label(nil)

          pairs.each_slice(2) do |key, value|
            commands.concat(compile_expr(key))
            # calc hash
            commands << [:stack, :dup]
            commands.concat(UNWRAP_COMMANDS)
            commands << [:stack, :push, HASH_SIZE]
            commands << [:calc, :mod]
            commands << [:stack, :push, 3]
            commands << [:calc, :multi]
            # stack: [key, hash]

            commands << [:stack, :push, hash_addr + 1] # hash_addr + 1 is the first item's address.
            commands << [:calc, :add]
            # stack: [key, key_addr]

            # Check collision
            commands << [:flow, :def, when_collision_label]
            commands << [:stack, :dup]
            commands << [:heap, :load]
            commands << [:stack, :push, NONE]
            commands << [:calc, :sub]
            # stack: [key, key_addr, is_none]

            commands << [:flow, :jump_if_zero, no_collision_label]

            # when collision
            commands << [:stack, :push, 2]
            commands << [:calc, :add]
            # stack: [key, next_addr]
            commands << [:heap, :load]
            # stack: [key, next_key_addr]
            commands << [:flow, :jump, when_collision_label]

            commands << [:flow, :def, no_collision_label]
            # End check collision

            # Save key
            commands << [:stack, :dup]
            commands << [:stack, :push, TMP_ADDR]
            commands << [:stack, :swap]
            commands << [:heap, :save]
            # stack: [key, key_addr]
            commands << [:stack, :swap]
            commands << [:heap, :save]
            # stack: []

            # Save value
            commands << [:stack, :push, TMP_ADDR]
            commands << [:heap, :load]
            commands << [:stack, :dup]
            # stack: [key_addr, key_addr]
            commands << [:stack, :push, 1]
            commands << [:calc, :add]
            commands.concat(compile_expr(value))
            # stack: [key_addr, value_addr, value]
            commands << [:heap, :save]
            # stack: [key_addr]

            # Save addr
            commands << [:stack, :push, 2]
            commands << [:calc, :add]
            # stack: [next_addr]
            commands << [:stack, :push, NONE_ADDR]
            commands << [:heap, :save]
          end
        end

        commands
      end

      private def commands_to_ws(commands)
        buf = +""
        commands.each do |command|
          case command
          in [:stack, :push, num]
            buf << SPACE << SPACE << num_to_ws(num)
          in [:stack, :pop]
            buf << SPACE << NL << NL
          in [:stack, :swap]
            buf << SPACE << NL << TAB
          in [:stack, :dup]
            buf << SPACE << NL << SPACE
          in [:heap, :save]
            buf << TAB << TAB << SPACE
          in [:heap, :load]
            buf << TAB << TAB << TAB
          in [:io, :write_char]
            buf << TAB << NL << SPACE << SPACE
          in [:io, :write_num]
            buf << TAB << NL << SPACE << TAB
          in [:io, :read_char]
            buf << TAB << NL << TAB << SPACE
          in [:io, :read_num]
            buf << TAB << NL << TAB << TAB
          in [:flow, :exit]
            buf << NL << NL << NL
          in [:flow, :call, num]
            buf << NL << SPACE << TAB << num_to_ws(num)
          in [:flow, :def, num]
            buf << NL << SPACE << SPACE << num_to_ws(num)
          in [:flow, :end]
            buf << NL << TAB << NL
          in [:flow, :jump_if_zero, label]
            buf << NL << TAB << SPACE << num_to_ws(label)
          in [:flow, :jump, label]
            buf << NL << SPACE << NL << num_to_ws(label)
          in [:flow, :jump_if_neg, label]
            buf << NL << TAB << TAB << num_to_ws(label)
          in [:calc, :add]
            buf << TAB << SPACE << SPACE << SPACE
          in [:calc, :sub]
            buf << TAB << SPACE << SPACE << TAB
          in [:calc, :multi]
            buf << TAB << SPACE << SPACE << NL
          in [:calc, :div]
            buf << TAB << SPACE << TAB << SPACE
          in [:calc, :mod]
            buf << TAB << SPACE << TAB << TAB
          end
        end
        buf
      end

      private def with_storing_lvars(commands, &block)
        lvars.each do |var_addr|
          # stack.push(addr); stack.push(val)
          commands << [:stack, :push, var_addr]
          commands << [:stack, :push, var_addr]
          commands << [:heap, :load]
        end

        block.call

        lvars.size.times do
          commands << [:heap, :save]
        end
      end

      # Compile fcall and vcall
      private def compile_call(name, args)
        commands = []
        with_storing_lvars(commands) do
          args.each do |arg|
            commands.concat(compile_expr(arg))
          end
          commands << [:flow, :call, ident_to_label(name)]
          commands << [:stack, :push, TMP_ADDR]
          commands << [:stack, :swap]
          commands << [:heap, :save]
        end
        commands << [:stack, :push, TMP_ADDR]
        commands << [:heap, :load]
        commands
      end

      # required stack: [count]
      # the count in the stack will be modified by this method.
      private def times(&block)
        commands = []
        end_label = ident_to_label(nil)
        cond_label = ident_to_label(nil)

        commands << [:flow, :def, cond_label]
        commands << [:stack, :push, 1]
        commands << [:calc, :sub]
        commands << [:stack, :dup]
        commands << [:flow, :jump_if_neg, end_label]

        commands.concat(block.call)

        commands << [:flow, :jump, cond_label]
        commands << [:flow, :def, end_label]

        commands
      end

      private def compile_if(cond, if_body, else_body)
        commands = []
        else_label = ident_to_label(nil)
        end_label = ident_to_label(nil)

        body = -> (x, sym) do
          commands.concat(compile_expr(x))
          commands.concat(UNWRAP_COMMANDS)
          commands << [:flow, sym, else_label]
          if else_body
            commands.concat(compile_expr(else_body))
          else
            commands << [:stack, :push, NIL]
          end
          commands << [:flow, :jump, end_label]
          commands << [:flow, :def, else_label]
          if if_body
            commands.concat(compile_expr(if_body))
          else
            commands << [:stack, :push, NIL]
          end
          commands << [:flow, :def, end_label]
        end

        case cond
        in [:OPCALL, [:LIT, 0], :==, [:ARRAY, x, nil]]
          body.(x, :jump_if_zero)
        in [:OPCALL, x, :==, [:ARRAY, [:LIT, 0], nil]]
          body.(x, :jump_if_zero)
        in [:OPCALL, x, :<, [:ARRAY, [:LIT, 0], nil]]
          body.(x, :jump_if_neg)
        in [:OPCALL, [:LIT, 0], :<, [:ARRAY, x, nil]]
          body.(x, :jump_if_neg)
        end

        commands
      end

      private def compile_while(cond, body)
        commands = []
        cond_label = ident_to_label(nil)
        body_label = ident_to_label(nil)
        end_label = ident_to_label(nil)

        make_body = -> (x, sym) do
          commands << [:flow, :def, cond_label]
          commands.concat(compile_expr(x))
          commands.concat(UNWRAP_COMMANDS)
          commands << [:flow, sym, body_label]
          commands << [:flow, :jump, end_label]
          commands << [:flow, :def, body_label]
          commands.concat(compile_expr(body))
          commands << [:flow, :jump, cond_label]
          commands << [:flow, :def, end_label]
        end

        case cond
        in [:OPCALL, [:LIT, 0], :==, [:ARRAY, x, nil]]
          make_body.(x, :jump_if_zero)
        in [:OPCALL, x, :==, [:ARRAY, [:LIT, 0], nil]]
          make_body.(x, :jump_if_zero)
        in [:OPCALL, x, :<, [:ARRAY, [:LIT, 0], nil]]
          make_body.(x, :jump_if_neg)
        in [:OPCALL, [:LIT, 0], :<, [:ARRAY, x, nil]]
          make_body.(x, :jump_if_neg)
        end

        commands
      end

      # Array#[]
      # stack: [recv, index], they're wrapped.
      private def array_index_access_label
        @array_index_access_label ||= (
          label = ident_to_label(nil)

          commands = []
          commands << [:flow, :def, label]

          commands << [:stack, :swap]
          commands.concat(UNWRAP_COMMANDS)
          commands << [:heap, :load]
          commands << [:stack, :swap]
          commands.concat(UNWRAP_COMMANDS)
          # stack: [addr_of_first_item, index]

          commands.concat(times do
            c = []
            c << [:stack, :swap]
            # stack: [index, addr_of_first_item]
            c << [:stack, :push, 1]
            c << [:calc, :add]
            c << [:heap, :load]
            # stack: [index, addr_of_next_item]
            c << [:stack, :swap]
            c
          end)
          commands << [:stack, :pop]
          # stack: [addr_of_the_target_item]
          commands << [:heap, :load]

          commands << [:flow, :end]
          @methods << commands
          label
        )
      end

      # Hash#[]
      # stack: [recv, key], they're wrapped.
      private def hash_index_access_label
        @hash_index_access_label ||= (
          label = ident_to_label(nil)
          key_not_collision_label = ident_to_label(nil)
          check_key_equivalent_label = ident_to_label(nil)

          commands = []
          commands << [:flow, :def, label]

          commands << [:stack, :swap]
          commands.concat(UNWRAP_COMMANDS)
          commands << [:heap, :load]
          commands << [:stack, :swap]
          # stack: [addr_of_first_key, key (wrapped)]
          commands.concat(SAVE_TMP_COMMANDS)

          # calc hash
          # stack: [addr_of_first_key, key (wrapped)]
          commands.concat(UNWRAP_COMMANDS)
          commands << [:stack, :push, HASH_SIZE]
          commands << [:calc, :mod]
          commands << [:stack, :push, 3]
          commands << [:calc, :multi]
          # stack: [addr_of_first_key, hash]

          commands << [:calc, :add]
          # stack: [addr_of_target_key]

          # Check key equivalent
          commands << [:flow, :def, check_key_equivalent_label]
          commands << [:stack, :dup]
          commands << [:heap, :load]
          commands.concat(LOAD_TMP_COMMANDS)
          # stack: [addr_of_target_key, target_key, key]
          commands << [:calc, :sub]
          commands << [:flow, :jump_if_zero, key_not_collision_label]
          # stack: [addr_of_target_key]

          # when collistion
          commands << [:stack, :push, 2]
          commands << [:calc, :add]
          # stack: [addr_of_next_key_addr]
          commands << [:heap, :load]
          # stack: [next_key_addr]
          commands << [:flow, :jump, check_key_equivalent_label]

          commands << [:flow, :def, key_not_collision_label]
          commands << [:stack, :push, 1]
          commands << [:calc, :add]
          # stack: [addr_of_target_value]
          commands << [:heap, :load]

          commands << [:flow, :end]
          @methods << commands
          label
        )
      end

      private def initialize_hash(hash_addr)
        commands = []

        addrs = (HASH_SIZE * 3).times.map { next_addr_index }

        addrs.each_slice(3) do |key_addr, _value_addr, _next_addr|
          commands << [:stack, :push, key_addr]
          commands << [:stack, :push, NONE]
          commands << [:heap, :save]
        end

        commands << [:stack, :push, hash_addr]
        commands << [:stack, :push, addrs[0]]
        commands << [:heap, :save]

        commands << [:stack, :push, with_type(hash_addr, TYPE_HASH)]

        commands
      end

      private def check_char!(char)
        raise ParserError, "String size must be 1, but it's #{char} (#{char.size})" if char.size != 1
      end

      private def num_to_ws(num)
        sign =
          if num < 0
            TAB
          else
            SPACE
          end
        sign + num.abs.to_s(2).gsub("1", TAB).gsub('0', SPACE) + NL
      end

      private def next_label_index
        @label_index += 1
      end

      private def ident_to_label(ident)
        if ident
          @labels[ident] ||= next_label_index
        else
          next_label_index
        end
      end

      private def next_addr_index
        @addr_index += 1
      end

      private def ident_to_addr(ident)
        @addrs[ident] ||= next_addr_index
      end

      private def with_type(val, type)
        (val << TYPE_BITS) + type
      end

      private def lvars
        @lvars_stack.last
      end
    end
  end
end
