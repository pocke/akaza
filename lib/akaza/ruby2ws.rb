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
    HEAP_COUNT_ADDR = 2

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
    WRAP_HASH_COMMANDS = [
      [:stack, :push, 2 ** TYPE_BITS],
      [:calc, :multi],
      [:stack, :push, TYPE_HASH],
      [:calc, :add],
    ].freeze
    SAVE_TMP_COMMANDS = [
      [:stack, :dup],
      [:stack, :push, TMP_ADDR],
      [:stack, :swap],
      [:heap, :save],
    ].freeze
    LOAD_TMP_COMMANDS = [
      [:stack, :push, TMP_ADDR],
      [:heap, :load],
    ].freeze
    # Allocate heap and push allocated address to the stack
    ALLOCATE_HEAP_COMMANDS = [
      [:stack, :push, HEAP_COUNT_ADDR],
      [:heap, :load],
      [:stack, :push, 1],
      [:calc, :add],
      [:stack, :dup],
      [:stack, :push, HEAP_COUNT_ADDR],
      [:stack, :swap],
      [:heap, :save],
    ].freeze
    ALLOCATE_NEW_HASH_ITEM_COMMANDS = [
      *ALLOCATE_HEAP_COMMANDS,
      [:stack, :dup],
      [:stack, :push, NONE],
      [:heap, :save],
      *ALLOCATE_HEAP_COMMANDS,
      [:stack, :pop],
      *ALLOCATE_HEAP_COMMANDS,
      [:stack, :pop],
    ].freeze

    class ParseError < StandardError; end

    def self.ruby_to_ws(ruby_code)
      Transpiler.new(ruby_code).transpile
    end

    class Transpiler
      def initialize(ruby_code)
        @ruby_code = ruby_code

        @variable_addr_index = 2
        @variable_addrs = {}

        @label_index = 0
        @labels = {}

        @methods = []
        @lvars_stack = [[]]
      end

      def transpile
        ast = RubyVM::AbstractSyntaxTree.parse(@ruby_code)
        commands = []
        body = compile_expr(ast)

        # Reserve heaps for local variables
        commands << [:stack, :push, HEAP_COUNT_ADDR]
        commands << [:stack, :push, @variable_addr_index + 1]
        commands << [:heap, :save]

        commands.concat body
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
          var_addr = variable_name_to_addr(var)
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
            m << [:stack, :push, variable_name_to_addr(args_name)]
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
          commands.concat ALLOCATE_HEAP_COMMANDS
          commands << [:stack, :dup]
          commands.concat(compile_expr(expr))
          commands << [:heap, :save]
          # stack: [array, unwrapped_addr_of_array, addr_of_first_item, new_item_value_addr]
          commands << [:stack, :swap]
          commands.concat ALLOCATE_HEAP_COMMANDS
          commands << [:stack, :swap]
          commands << [:heap, :save]
          # stack: [array, unwrapped_addr_of_array, new_item_value_addr]

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
          commands << [:stack, :push, variable_name_to_addr(name)]
          commands << [:heap, :load]
        in [:ARRAY, *items, nil]
          commands.concat ALLOCATE_HEAP_COMMANDS
          commands << [:stack, :dup]
          commands << [:stack, :dup]
          # stack: [array_addr, array_addr, array_addr]
          commands << [:stack, :push, 1]
          commands << [:calc, :add]
          # stack: [array_addr, array_addr, first_item_addr]
          commands << [:heap, :save]
          # stack: [array_addr]

          items.each.with_index do |item, index|
            # save value
            commands.concat ALLOCATE_HEAP_COMMANDS
            commands.concat compile_expr(item)
            commands << [:heap, :save]

            # save next address
            commands.concat ALLOCATE_HEAP_COMMANDS
            if index == items.size - 1
              commands << [:stack, :push, NONE_ADDR]
            else
              commands << [:stack, :dup]
              commands << [:stack, :push, 1]
              commands << [:calc, :add]
            end
            commands << [:heap, :save]
          end

          commands.concat WRAP_ARRAY_COMMANDS
        in [:ZARRAY]
          commands.concat ALLOCATE_HEAP_COMMANDS
          commands << [:stack, :dup]
          commands << [:stack, :push, NONE_ADDR]
          commands << [:heap, :save]
          commands.concat WRAP_ARRAY_COMMANDS
        in [:HASH, nil]
          commands.concat initialize_hash
        in [:HASH, [:ARRAY, *pairs, nil]]
          commands.concat initialize_hash
          commands << [:stack, :dup]
          commands.concat UNWRAP_COMMANDS
          commands.concat SAVE_TMP_COMMANDS
          commands << [:stack, :pop]
          # stack: [hash_object (unwrapped)]
          # tmp: hash_object (unwrapped)

          pairs.each_slice(2) do |key, value|
            no_collision_label = ident_to_label(nil)
            check_collision_label = ident_to_label(nil)
            when_not_allocated = ident_to_label(nil)

            commands.concat(compile_expr(key))
            # calc hash
            commands << [:stack, :dup]
            commands.concat(UNWRAP_COMMANDS)
            commands << [:stack, :push, HASH_SIZE]
            commands << [:calc, :mod]
            commands << [:stack, :push, 3]
            commands << [:calc, :multi]
            # stack: [key, hash]

            commands.concat LOAD_TMP_COMMANDS
            commands << [:stack, :push, 1]
            commands << [:calc, :add] # hash_addr + 1 is the first item's address.
            commands << [:calc, :add]
            # stack: [key, key_addr]

            # Check collision
            commands << [:flow, :def, check_collision_label]
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
            commands << [:stack, :dup]
            commands << [:heap, :load]
            commands << [:stack, :push, NONE_ADDR]
            commands << [:calc, :sub]
            commands << [:flow, :jump_if_zero, when_not_allocated]
            # stack: [key, next_addr]

            # when next field is already allocated
            commands << [:heap, :load]
            # stack: [key, next_key_addr]
            commands << [:flow, :jump, check_collision_label]

            # when next field is not allocated
            commands << [:flow, :def, when_not_allocated]
            # stack: [key, next_addr]
            commands << [:stack, :dup]
            commands.concat ALLOCATE_NEW_HASH_ITEM_COMMANDS
            commands << [:heap, :save]
            commands << [:heap, :load]

            commands << [:flow, :jump, check_collision_label]

            commands << [:flow, :def, no_collision_label]
            # End check collision

            # stack: [key, key_addr]
            # Save value
            commands << [:stack, :dup]
            commands << [:stack, :push, 1]
            commands << [:calc, :add]
            commands.concat(compile_expr(value))
            # stack: [key, key_addr, value_addr, value]
            commands << [:heap, :save]
            # stack: [key, key_addr]

            # Save next addr
            commands << [:stack, :dup]
            commands << [:stack, :push, 2]
            commands << [:calc, :add]
            # stack: [key, key_addr, next_addr]
            commands << [:stack, :push, NONE_ADDR]
            commands << [:heap, :save]
            # stack: [key, key_addr]

            # Save key
            commands << [:stack, :swap]
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

      private def initialize_hash
        commands = []
        # Allocate for Hash
        commands.concat ALLOCATE_HEAP_COMMANDS

        HASH_SIZE.times do
          commands.concat ALLOCATE_NEW_HASH_ITEM_COMMANDS
          commands << [:stack, :pop]
        end

        # stack: [hash_addr]
        commands << [:stack, :dup]
        commands << [:stack, :dup]
        commands << [:stack, :push, 1]
        commands << [:calc, :add]
        commands << [:heap, :save]
        # stack: [hash_addr]

        commands.concat(WRAP_HASH_COMMANDS)

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

      private def variable_addr_index
        @variable_addr_index += 1
      end

      private def variable_name_to_addr(ident)
        @variable_addrs[ident] ||= variable_addr_index
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
