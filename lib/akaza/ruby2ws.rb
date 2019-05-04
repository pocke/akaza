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

    TYPES = %w[Integer Hash Array]
    TYPE_BITS = 2

    TYPE_SPECIAL = 0b00
    TYPE_INT     = 0b01
    TYPE_ARRAY   = 0b10
    TYPE_HASH    = 0b11

    HASH_SIZE = 11

    FALSE = 0 << TYPE_BITS + TYPE_SPECIAL
    # NONE is for internal. It does not available for user.
    NONE = 1 << TYPE_BITS + TYPE_SPECIAL
    TRUE = 2 << TYPE_BITS + TYPE_SPECIAL
    # NIL is nil
    NIL = 4 << TYPE_BITS + TYPE_SPECIAL

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

    prelude_path = File.expand_path('./ruby2ws/prelude.rb', __dir__)
    PRELUDE_AST = RubyVM::AbstractSyntaxTree.parse(File.read(prelude_path))

    class ParseError < StandardError; end

    def self.ruby_to_ws(ruby_code, path: '(eval)')
      Transpiler.new(ruby_code, path: path).transpile
    end

    class Transpiler
      # @param ruby_code [String]
      # @param path [String] For debug information
      def initialize(ruby_code, path:)
        @ruby_code = ruby_code
        @path = path

        @variable_addr_index = 2
        @variable_addrs = {}

        @label_index = 0
        @labels = {}

        # Array<Array<Command>>
        @methods = []
        @method_table = {
          Array: [:unshift, :shift, :[], :[]=],
          Integer: [],
          Hash: [:[], :[]=],
        }
        @lvars_stack = [[variable_name_to_addr(:self)]]

        @current_class = nil
      end

      def transpile
        commands = []
        # define built-in functions
        define_array_shift
        define_array_unshift
        define_array_ref
        define_array_attr_asgn
        define_hash_ref

        # Prelude
        commands.concat compile_expr(PRELUDE_AST)

        ast = RubyVM::AbstractSyntaxTree.parse(@ruby_code)
        body = compile_expr(ast)

        # Save self for top level
        commands << [:stack, :push, variable_name_to_addr(:self)]
        commands << [:stack, :push, NONE]
        commands << [:heap, :save]

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
        in [:FCALL, :raise, [:ARRAY, [:STR, str], nil]]
          commands.concat compile_raise(str, node)
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
        in [:OPCALL, l, :==, [:ARRAY, r, nil]]
          commands.concat compile_expr(l)
          commands.concat compile_expr(r)
          commands << [:flow, :call, op_eqeq_label]
        in [:OPCALL, l, :<=>, [:ARRAY, r, nil]]
          commands.concat compile_expr(l)
          commands.concat compile_expr(r)
          commands << [:flow, :call, op_spaceship_label]
        in [:OPCALL, l, :<, [:ARRAY, r, nil]]
          commands.concat compile_expr(l)
          commands.concat compile_expr(r)
          commands << [:flow, :call, op_lt_label]
        in [:OPCALL, l, :>, [:ARRAY, r, nil]]
          commands.concat compile_expr(l)
          commands.concat compile_expr(r)
          commands << [:flow, :call, op_gt_label]
        in [:OPCALL, l, :<=, [:ARRAY, r, nil]]
          commands.concat compile_expr(l)
          commands.concat compile_expr(r)
          commands << [:flow, :call, op_lteq_label]
        in [:OPCALL, l, :>=, [:ARRAY, r, nil]]
          commands.concat compile_expr(l)
          commands.concat compile_expr(r)
          commands << [:flow, :call, op_gteq_label]
        in [:OPCALL, l, :!=, [:ARRAY, r, nil]]
          commands.concat compile_expr(l)
          commands.concat compile_expr(r)
          commands << [:flow, :call, op_eqeq_label]
          commands << [:flow, :call, op_not_label]
        in [:OPCALL, recv, :!, nil]
          commands.concat compile_expr(recv)
          commands << [:flow, :call, op_not_label]
        in [:OPCALL, l, sym, [:ARRAY, r, nil]]
          com = {'+': :add, '-': :sub, '*': :multi, '/': :div, '%': :mod}[sym]
          raise ParseError, "Unknown symbol: #{sym}" unless com
          commands.concat(compile_expr(l))
          commands.concat(UNWRAP_COMMANDS)
          commands.concat(compile_expr(r))
          commands.concat(UNWRAP_COMMANDS)
          commands << [:calc, com]
          commands.concat(WRAP_NUMBER_COMMANDS)
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
        in [:CDECL, var, arg]
          commands.concat(compile_expr(arg))
          commands << [:stack, :dup]
          var_addr = variable_name_to_addr(var)
          commands << [:stack, :push, var_addr]
          commands << [:stack, :swap]
          commands << [:heap, :save]
        in [:ATTRASGN, recv, :[]=, [:ARRAY, index, value, nil]]
          commands.concat compile_expr(recv)
          commands.concat SAVE_TMP_COMMANDS
          commands.pop
          commands.concat compile_call_with_recv(:[]=, [index, value], error_target_node: node, explicit_self: true)
        in [:DEFN, name, [:SCOPE, lvar_table, [:ARGS, args_count ,*_], body]]
          self_addr = variable_name_to_addr(:self)
          label = @current_class ? ident_to_label(:"#{@current_class}##{name}") : ident_to_label(name)
          m = [
            [:flow, :def, label],

            # Restore self
            [:stack, :push, self_addr],
            [:stack, :swap],
            [:heap, :save],
          ]
          @lvars_stack << [self_addr]
          lvar_table[0...args_count].reverse.each do |args_name|
            addr = variable_name_to_addr(args_name)
            lvars << addr
            m << [:stack, :push, addr]
            m << [:stack, :swap]
            m << [:heap, :save]
          end

          m.concat(compile_expr(body))
          @lvars_stack.pop
          m << [:flow, :end]

          @methods << m

          @method_table[@current_class] << name if @current_class
          commands << [:stack, :push, NIL] # def foo... returns nil
        in [:CLASS, [:COLON2, nil, class_name], nil, scope]
          raise ParseError, "Class cannot be nested, but #{@current_class}::#{class_name} is nested." if @current_class
          @current_class = class_name
          commands.concat compile_expr(scope)
          @current_class = nil
        in [:SCOPE, _, _, body]
          commands.concat(compile_expr(body))
        in [:BEGIN, nil]
          # skip
          # It is available in class definition.
          commands << [:stack, :push, NIL]
        in [:SELF]
          commands.concat load_from_self_commands
        in [:BLOCK, *children]
          children.each.with_index do |child, index|
            commands.concat(compile_expr(child))
            commands << [:stack, :pop] unless index == children.size - 1
          end
        in [:VCALL, name]
          commands << [:stack, :push, variable_name_to_addr(:self)]
          commands << [:heap, :load]
          commands.concat compile_call_with_recv(name, [], error_target_node: node, explicit_self: false)
        in [:FCALL, name, [:ARRAY, *args, nil]]
          commands << [:stack, :push, variable_name_to_addr(:self)]
          commands << [:heap, :load]
          commands.concat compile_call_with_recv(name, args, error_target_node: node, explicit_self: false)
        in [:CALL, recv, name, [:ARRAY, *args, nil]]
          commands.concat compile_expr(recv)
          commands.concat compile_call_with_recv(name, args, error_target_node: recv, explicit_self: true)
        in [:CALL, recv, name, nil]
          args = []
          commands.concat compile_expr(recv)
          commands.concat compile_call_with_recv(name, args, error_target_node: recv, explicit_self: true)
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
        in [:TRUE]
          commands << [:stack, :push, TRUE]
        in [:FALSE]
          commands << [:stack, :push, FALSE]
        in [:NIL]
          commands << [:stack, :push, NIL]
        in [:LVAR, name]
          commands << [:stack, :push, variable_name_to_addr(name)]
          commands << [:heap, :load]
        in [:CONST, name]
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

      # Compile FCALL and VCALL
      private def compile_call(name, args, self_commands)
        commands = []
        with_storing_lvars(commands) do
          # push args
          args.each do |arg|
            commands.concat(compile_expr(arg))
          end
          # push self
          commands.concat self_commands

          commands << [:flow, :call, ident_to_label(name)]
          commands << [:stack, :push, TMP_ADDR]
          commands << [:stack, :swap]
          commands << [:heap, :save]
        end
        # restore return value
        commands << [:stack, :push, TMP_ADDR]
        commands << [:heap, :load]
        commands
      end

      # Compile CALL
      # stack: [recv]
      private def compile_call_with_recv(name, args, error_target_node:, explicit_self:)
        commands = []

        is_int_label = ident_to_label(nil)
        is_array_label = ident_to_label(nil)
        is_hash_label = ident_to_label(nil)
        is_none_label = ident_to_label(nil)
        end_label = ident_to_label(nil)

        commands.concat SAVE_TMP_COMMANDS

        self_commands = LOAD_TMP_COMMANDS

        # is_a?(Integer)
        commands << [:stack, :push, TYPE_INT]
        commands << [:stack, :swap]
        commands << [:flow, :call, is_a_label]
        commands << [:flow, :jump_if_zero, is_int_label]

        # is_a?(Array)
        commands << [:stack, :push, TYPE_ARRAY]
        commands.concat LOAD_TMP_COMMANDS
        commands << [:flow, :call, is_a_label]
        commands << [:flow, :jump_if_zero, is_array_label]

        # is_a?(Hash)
        commands << [:stack, :push, TYPE_HASH]
        commands.concat LOAD_TMP_COMMANDS
        commands << [:flow, :call, is_a_label]
        commands << [:flow, :jump_if_zero, is_hash_label]

        # == NONE
        commands.concat LOAD_TMP_COMMANDS
        commands << [:stack, :push, NONE]
        commands << [:calc, :sub]
        commands << [:flow, :jump_if_zero, is_none_label]

        # Other
        commands.concat compile_raise("Unknown type of receiver", error_target_node)

        top_level_p = -> (type) { !@method_table[type].include?(name) && !explicit_self }
        push_none = [[:stack, :push, NONE]]

        commands << [:flow, :def, is_int_label]
        if top_level_p.(:Integer)
          commands.concat compile_call(name, args, push_none)
        else
          commands.concat compile_call(:"Integer##{name}", args, self_commands)
        end
        commands << [:flow, :jump, end_label]

        commands << [:flow, :def, is_array_label]
        if top_level_p.(:Array)
          commands.concat compile_call(name, args, push_none)
        else
          commands.concat compile_call(:"Array##{name}", args, self_commands)
        end
        commands << [:flow, :jump, end_label]

        commands << [:flow, :def, is_hash_label]
        if top_level_p.(:Hash)
          commands.concat compile_call(name, args, push_none)
        else
          commands.concat compile_call(:"Hash##{name}", args, self_commands)
        end
        commands << [:flow, :jump, end_label]

        # If receiver is NONE, it means method is called at the top level
        commands << [:flow, :def, is_none_label]
        commands.concat compile_call(name, args, [[:stack, :push, NONE]])

        commands << [:flow, :def, end_label]

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

        optimized_body = -> (x, sym) do
          else_label = ident_to_label(nil)
          end_label = ident_to_label(nil)

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
          optimized_body.(x, :jump_if_zero)
        in [:OPCALL, x, :==, [:ARRAY, [:LIT, 0], nil]]
          optimized_body.(x, :jump_if_zero)
        in [:OPCALL, x, :<, [:ARRAY, [:LIT, 0], nil]]
          optimized_body.(x, :jump_if_neg)
        in [:OPCALL, [:LIT, 0], :<, [:ARRAY, x, nil]]
          optimized_body.(x, :jump_if_neg)
        else
          if_label = ident_to_label(nil)
          end_label = ident_to_label(nil)

          commands.concat compile_expr(cond)
          commands << [:flow, :call, rtest_label]
          commands << [:flow, :jump_if_zero, if_label]

          # when false
          if else_body
            commands.concat compile_expr(else_body)
          else
            commands << [:stack, :push, NIL]
          end
          commands << [:flow, :jump, end_label]

          # when true
          commands << [:flow, :def, if_label]
          if if_body
            commands.concat compile_expr(if_body)
          else
            commands << [:stack, :push, NIL]
          end

          commands << [:flow, :def, end_label]
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

      private def compile_raise(str, node)
        msg = +"#{@path}:"
        msg << "#{node.first_lineno}:#{node.first_column}"
        msg << ": #{str} (Error)\n"
        commands = []

        msg.bytes.each do |byte|
          commands << [:stack, :push, byte]
          commands << [:io, :write_char]
        end

        commands << [:flow, :exit]

        commands
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

      # stack: [self]
      # return stack: [self]
      private def save_to_self_commands
        commands = []
        self_addr = variable_name_to_addr(:self)
        commands << [:stack, :dup]
        commands << [:stack, :push, self_addr]
        commands << [:stack, :swap]
        commands << [:heap, :save]
        commands
      end

      # stack: []
      # return stack: [self]
      private def load_from_self_commands
        commands = []
        self_addr = variable_name_to_addr(:self)
        commands << [:stack, :push, self_addr]
        commands << [:heap, :load]
        commands
      end

      # stack: [left, right]
      # return stack: [TRUE/FALSE]
      private def op_eqeq_label
        @op_eqeq_label ||= (
          label = ident_to_label(nil)
          label_if_zero = ident_to_label(nil)
          label_end = ident_to_label(nil)

          commands = []
          commands << [:flow, :def, label]

          commands << [:calc, :sub]
          commands << [:flow, :jump_if_zero, label_if_zero]
          commands << [:stack, :push, FALSE]
          commands << [:flow, :jump, label_end]

          commands << [:flow, :def, label_if_zero]
          commands << [:stack, :push, TRUE]

          commands << [:flow, :def, label_end]
          commands << [:flow, :end]
          @methods << commands
          label
        )
      end

      # Object#<=>
      # stack: [left, right]
      # return stack: [-1/0/1]
      #   if left < rigth  then -1
      #   if left == rigth then 0
      #   if left > rigth then 1
      private def op_spaceship_label
        @op_spaceship_label ||= (
          label = ident_to_label(nil)
          zero_label = ident_to_label(nil)
          end_label = ident_to_label(nil)
          neg_label = ident_to_label(nil)
          commands = []
          commands << [:flow, :def, label]

          commands << [:calc, :sub]
          commands << [:stack, :dup]
          commands << [:flow, :jump_if_zero, zero_label]

          commands << [:flow, :jump_if_neg, neg_label]

          # if positive
          commands << [:stack, :push, with_type(1, TYPE_INT)]
          commands << [:flow, :jump, end_label]

          # if negative
          commands << [:flow, :def, neg_label]
          commands << [:stack, :push, with_type(-1, TYPE_INT)]
          commands << [:flow, :jump, end_label]

          # if equal
          commands << [:flow, :def, zero_label]
          commands << [:stack, :pop]
          commands << [:stack, :push, with_type(0, TYPE_INT)]

          commands << [:flow, :def, end_label]
          commands << [:flow, :end]
          @methods << commands
          label
        )
      end

      # Object#<
      # stack: [left, right]
      # return stack: [TRUE/FALSE]
      private def op_lt_label
        @op_lt_label ||= (
          label = ident_to_label(nil)
          true_label = ident_to_label(nil)
          end_label = ident_to_label(nil)
          commands = []
          commands << [:flow, :def, label]

          commands << [:flow, :call, op_spaceship_label]
          commands << [:flow, :jump_if_neg, true_label]

          commands << [:stack, :push, FALSE]
          commands << [:flow, :jump, end_label]

          commands << [:flow, :def, true_label]
          commands << [:stack, :push, TRUE]

          commands << [:flow, :def, end_label]
          commands << [:flow, :end]
          @methods << commands
          label
        )
      end

      # Object#>
      # stack: [left, right]
      # return stack: [TRUE/FALSE]
      private def op_gt_label
        @op_gt_label ||= (
          label = ident_to_label(nil)
          false_label = ident_to_label(nil)
          end_label = ident_to_label(nil)
          commands = []
          commands << [:flow, :def, label]

          commands << [:flow, :call, op_spaceship_label]
          commands << [:flow, :jump_if_neg, false_label]

          commands << [:stack, :push, TRUE]
          commands << [:flow, :jump, end_label]

          commands << [:flow, :def, false_label]
          commands << [:stack, :push, FALSE]

          commands << [:flow, :def, end_label]
          commands << [:flow, :end]
          @methods << commands
          label
        )
      end

      # Object#<=
      # stack: [left, right]
      # return stack: [TRUE/FALSE]
      private def op_lteq_label
        @op_lteq_label ||= (
          label = ident_to_label(nil)
          true_label = ident_to_label(nil)
          end_label = ident_to_label(nil)
          commands = []
          commands << [:flow, :def, label]

          commands << [:flow, :call, op_spaceship_label]
          commands.concat UNWRAP_COMMANDS
          commands << [:stack, :push, 1]
          commands << [:calc, :sub]
          commands << [:flow, :jump_if_neg, true_label]

          commands << [:stack, :push, FALSE]
          commands << [:flow, :jump, end_label]

          commands << [:flow, :def, true_label]
          commands << [:stack, :push, TRUE]

          commands << [:flow, :def, end_label]
          commands << [:flow, :end]
          @methods << commands
          label
        )
      end

      # Object#>=
      # stack: [left, right]
      # return stack: [TRUE/FALSE]
      private def op_gteq_label
        @op_gteq_label ||= (
          label = ident_to_label(nil)
          true_label = ident_to_label(nil)
          end_label = ident_to_label(nil)
          commands = []
          commands << [:flow, :def, label]

          commands << [:flow, :call, op_spaceship_label]
          commands.concat UNWRAP_COMMANDS
          commands << [:stack, :push, 1]
          commands << [:calc, :add]
          commands << [:stack, :push, -1]
          commands << [:calc, :multi]
          commands << [:flow, :jump_if_neg, true_label]

          commands << [:stack, :push, FALSE]
          commands << [:flow, :jump, end_label]

          commands << [:flow, :def, true_label]
          commands << [:stack, :push, TRUE]

          commands << [:flow, :def, end_label]
          commands << [:flow, :end]
          @methods << commands
          label
        )
      end

      # stack: [obj]
      # return stack: [TRUE/FALSE]
      private def op_not_label
        @op_not_label ||= (
          label = ident_to_label(nil)
          true_label = ident_to_label(nil)
          end_label = ident_to_label(nil)

          commands = []
          commands << [:flow, :def, label]

          commands << [:flow, :call, rtest_label]
          commands << [:flow, :jump_if_zero, true_label]

          # when obj is falsy
          commands << [:stack, :push, TRUE]
          commands << [:flow, :jump, end_label]

          # when obj is truthy
          commands << [:flow, :def, true_label]
          commands << [:stack, :push, FALSE]

          commands << [:flow, :def, end_label]
          commands << [:flow, :end]
          @methods << commands
          label
        )
      end

      # stack: [target]
      # return stack: [0/1] if true then 0, if false then 1.
      private def rtest_label
        @rtest_label ||= (
          truthy = 0
          falsy = 1

          label = ident_to_label(nil)
          when_nil_label = ident_to_label(nil)
          when_false_label = ident_to_label(nil)
          end_label = ident_to_label(nil)

          commands = []
          commands << [:flow, :def, label]

          commands << [:stack, :dup]
          commands << [:stack, :push, NIL]
          commands << [:calc, :sub]
          commands << [:flow, :jump_if_zero, when_nil_label]

          commands << [:stack, :push, FALSE]
          commands << [:calc, :sub]
          commands << [:flow, :jump_if_zero, when_false_label]

          # when truthy
          commands << [:stack, :push, truthy]
          commands << [:flow, :jump, end_label]

          # when nil
          commands << [:flow, :def, when_nil_label]
          commands << [:stack, :pop]
          # when false
          commands << [:flow, :def, when_false_label]
          commands << [:stack, :push, falsy]

          commands << [:flow, :def, end_label]
          commands << [:flow, :end]
          @methods << commands
          label
        )
      end

      # stack: [type, val]
      # return stack: [int]
      #   if val is a type then 0
      #   if not then other int
      private def is_a_label
        @is_a_label ||= (
          label = ident_to_label(nil)

          commands = []
          commands << [:flow, :def, label]

          commands << [:stack, :push, 2 ** TYPE_BITS]
          commands << [:calc, :mod]
          commands << [:calc, :sub]

          commands << [:flow, :end]
          @methods << commands
          label
        )
      end

      # Array#shift
      # stack: [recv]
      private def define_array_shift
        label = ident_to_label(:'Array#shift')
        commands = []
        commands << [:flow, :def, label]

        commands.concat save_to_self_commands

        commands.concat(UNWRAP_COMMANDS)
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
        commands << [:flow, :end]
        # stack: [first_item]
        @methods << commands
      end

      # Array#unshift
      # stack: [arg, recv]
      private def define_array_unshift
        label = ident_to_label(:'Array#unshift')
        commands = []
        commands << [:flow, :def, label]

        # Restore self
        commands.concat save_to_self_commands
        commands << [:stack, :pop]
        # stack: [arg]
        commands.concat SAVE_TMP_COMMANDS
        commands << [:stack, :pop]
        # stack: []

        commands.concat load_from_self_commands
        commands.concat(UNWRAP_COMMANDS)
        # stack: [unwrapped_addr_of_array]

        commands << [:stack, :dup]
        commands << [:heap, :load]
        # stack: [unwrapped_addr_of_array, addr_of_first_item]

        # Allocate a new item
        commands.concat ALLOCATE_HEAP_COMMANDS
        commands << [:stack, :dup]
        commands.concat LOAD_TMP_COMMANDS
        commands << [:heap, :save]
        # stack: [unwrapped_addr_of_array, addr_of_first_item, new_item_value_addr]
        commands << [:stack, :swap]
        commands.concat ALLOCATE_HEAP_COMMANDS
        # stack: [unwrapped_addr_of_array, new_item_value_addr, addr_of_first_item, new_item_next_addr_addr]
        commands << [:stack, :swap]
        commands << [:heap, :save]
        # stack: [unwrapped_addr_of_array, new_item_value_addr]
        commands << [:heap, :save]

        commands.concat load_from_self_commands
        # stack: [self]
        commands << [:flow, :end]
        @methods << commands
      end

      # Array#[]
      # stack: [index, recv]
      private def define_array_ref
        label = ident_to_label(:'Array#[]')

        commands = []
        commands << [:flow, :def, label]

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
      end

      # Array#[]=
      # stack: [index, value, recv]
      private def define_array_attr_asgn
        label = ident_to_label(:'Array#[]=')

        commands = []
        commands << [:flow, :def, label]

        commands.concat save_to_self_commands
        commands << [:stack, :pop]
        commands << [:stack, :swap]
        # stack: [value, index]

        commands.concat load_from_self_commands
        commands.concat(UNWRAP_COMMANDS)
        commands << [:heap, :load]
        commands << [:stack, :swap]
        # stack: [value, addr_of_first_item, index]

        commands.concat(UNWRAP_COMMANDS)
        commands.concat(times do
          c = []
          c << [:stack, :swap]
          # stack: [value, index, addr_of_first_item]
          c << [:stack, :push, 1]
          c << [:calc, :add]
          c << [:heap, :load]
          # stack: [value, index, addr_of_next_item]
          c << [:stack, :swap]
          c
        end)
        commands << [:stack, :pop] # pop index
        commands.concat SAVE_TMP_COMMANDS
        # stack: [value, addr_of_the_target_item]

        commands << [:stack, :swap]
        commands << [:heap, :save]
        # stack: []
        commands.concat LOAD_TMP_COMMANDS
        commands << [:heap, :load]

        commands << [:flow, :end]
        @methods << commands
      end

      # Hash#[]
      # stack: [key, recv]
      private def define_hash_ref
        label = ident_to_label(:'Hash#[]')
        key_not_collision_label = ident_to_label(nil)
        check_key_equivalent_label = ident_to_label(nil)

        commands = []
        commands << [:flow, :def, label]

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
      end

      private def check_char!(char)
        raise ParseError, "String size must be 1, but it's #{char} (#{char.size})" if char.size != 1
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

      # @param ident [Symbol | nil]
      private def ident_to_label(ident)
        if ident
          ident = ident.to_sym
          @labels[ident] ||= next_label_index
           # .tap {|index| p [ident, num_to_ws(index)]}
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
