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

    ARRAY_FIRST_CAPACITY = 10

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
    # OPTIMIZE
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
    # Return an address that will be allocated by ALLOCATE_HEAP_COMMANDS
    NEXT_HEAP_ADDRESS = [
      [:stack, :push, HEAP_COUNT_ADDR],
      [:heap, :load],
      [:stack, :push, 1],
      [:calc, :add],
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
          Array: [:size, :push, :pop, :[], :[]=],
          Integer: [],
          Hash: [:[], :[]=],
        }
        @lvars_stack = []

        @current_class = nil
      end

      def transpile
        commands = []
        # define built-in functions
        define_array_size
        define_array_pop
        define_array_push
        define_array_ref
        define_array_attr_asgn
        define_hash_ref
        define_hash_attr_asgn
        define_op_spaceship

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
        in [:OPCALL, l, :!=, [:ARRAY, r, nil]]
          commands.concat compile_expr(l)
          commands.concat compile_expr(r)
          commands << [:flow, :call, op_eqeq_label]
          commands << [:flow, :call, op_not_label]
        in [:OPCALL, recv, :!, nil]
          commands.concat compile_expr(recv)
          commands << [:flow, :call, op_not_label]
        in [:OPCALL, l, :+ | :- | :* | :/ | :% => sym, [:ARRAY, r, nil]]
          com = {'+': :add, '-': :sub, '*': :multi, '/': :div, '%': :mod}[sym]
          commands.concat(compile_expr(l))
          commands.concat(UNWRAP_COMMANDS)
          commands.concat(compile_expr(r))
          commands.concat(UNWRAP_COMMANDS)
          commands << [:calc, com]
          commands.concat(WRAP_NUMBER_COMMANDS)
        in [:OPCALL, recv, op, [:ARRAY, *args, nil]]
          commands.concat compile_expr(recv)
          commands.concat compile_call_with_recv(op, args, error_target_node: recv, explicit_self: true)
        in [:VCALL, :exit]
          commands << [:flow, :exit]
        in [:LASGN, var, arg]
          commands.concat(compile_expr(arg))
          commands << [:stack, :dup]
          var_addr = variable_name_to_addr(var)
          commands << [:stack, :push, var_addr]
          commands << [:stack, :swap]
          commands << [:heap, :save]
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
          label = @current_class ? ident_to_label(:"#{@current_class}##{name}") : ident_to_label(name)
          m = [
            [:flow, :def, label],
          ]
          self_addr = variable_name_to_addr(:self)
          m.concat update_lvar_commands(lvar_table)
          lvar_table[0...args_count].reverse.each do |args_name|
            addr = variable_name_to_addr(args_name)
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
        in [:SCOPE, lvar_table, _, body]
          commands.concat update_lvar_commands(lvar_table)
          commands.concat(compile_expr(body))
          @lvars_stack.pop
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
          commands.concat allocate_array_commands(items.size)
          # stack: [array]

          commands << [:stack, :dup]
          commands.concat UNWRAP_COMMANDS
          commands << [:stack, :push, 3]
          commands << [:calc, :add]
          # stack: [array, first_item_addr]

          items.each do |item|
            commands << [:stack, :dup]
            # stack: [array, item_addr, item_addr]
            commands.concat compile_expr(item)
            commands << [:heap, :save]
            commands << [:stack, :push, 1]
            commands << [:calc, :add]
            # stack: [array, next_item_addr]
          end
          commands << [:stack, :pop]

        in [:ZARRAY]
          # Allocate array ref
          commands.concat allocate_array_commands(0)
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

      # stack: [recv]
      private def compile_call(name, args)
        commands = []
        commands.concat SAVE_TMP_COMMANDS
        commands << [:stack, :pop]
        with_storing_lvars(commands) do
          # save self
          commands.concat LOAD_TMP_COMMANDS
          commands.concat save_to_self_commands
          commands << [:stack, :pop]

          # push args
          args.each do |arg|
            commands.concat(compile_expr(arg))
          end

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

        commands << [:flow, :def, is_int_label]
        if top_level_p.(:Integer)
          commands << [:stack, :push, NONE]
          commands.concat compile_call(name, args)
        else
          commands.concat LOAD_TMP_COMMANDS
          commands.concat compile_call(:"Integer##{name}", args)
        end
        commands << [:flow, :jump, end_label]

        commands << [:flow, :def, is_array_label]
        if top_level_p.(:Array)
          commands << [:stack, :push, NONE]
          commands.concat compile_call(name, args)
        else
          commands.concat LOAD_TMP_COMMANDS
          commands.concat compile_call(:"Array##{name}", args)
        end
        commands << [:flow, :jump, end_label]

        commands << [:flow, :def, is_hash_label]
        if top_level_p.(:Hash)
          commands << [:stack, :push, NONE]
          commands.concat compile_call(name, args)
        else
          commands.concat LOAD_TMP_COMMANDS
          commands.concat compile_call(:"Hash##{name}", args)
        end
        commands << [:flow, :jump, end_label]

        # If receiver is NONE, it means method is called at the top level
        commands << [:flow, :def, is_none_label]
        commands << [:stack, :push, NONE]
        commands.concat compile_call(name, args)

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
          commands << [:stack, :pop]
          commands << [:flow, :jump, cond_label]
          commands << [:flow, :def, end_label]
          commands << [:stack, :push, NIL]
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
        else
          commands << [:flow, :def, cond_label]
          commands.concat(compile_expr(cond))
          commands << [:flow, :call, rtest_label]
          commands << [:flow, :jump_if_zero, body_label]
          commands << [:flow, :jump, end_label]
          commands << [:flow, :def, body_label]
          commands.concat(compile_expr(body))
          commands << [:stack, :pop]
          commands << [:flow, :jump, cond_label]
          commands << [:flow, :def, end_label]
          commands << [:stack, :push, NIL]
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

      # OPTIMIZE
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

      # stack: [addr_of_first_addr]
      # return stack: []
      private def realloc_array_label
        @realloc_array_label ||= (
          label = ident_to_label(nil)
          commands = []
          commands << [:flow, :def, label]

          # stack: [addr_of_first_addr]
          # Get cap addr
          commands << [:stack, :dup]
          commands << [:stack, :push, 2]
          commands << [:calc, :add]
          commands << [:stack, :dup]
          commands << [:heap, :load]
          # stack: [addr_of_first_addr, cap_addr, cap]
          commands << [:stack, :push, 2]
          commands << [:calc, :multi]
          # stack: [addr_of_first_addr, cap_addr, new_cap]
          # Update cap
          commands.concat SAVE_TMP_COMMANDS
          commands << [:heap, :save]
          commands.concat LOAD_TMP_COMMANDS
          # stack: [addr_of_first_addr, new_cap]
          commands.concat NEXT_HEAP_ADDRESS
          commands.concat SAVE_TMP_COMMANDS # new_item_addr
          commands << [:stack, :pop]
          # Allocate new addresses
          commands.concat(times do
            c = []
            c.concat ALLOCATE_HEAP_COMMANDS
            c << [:stack, :pop]
            c
          end)
          commands << [:stack, :pop]
          # stack: [addr_of_first_addr]
          commands << [:stack, :dup]
          commands << [:heap, :load]
          # stack: [addr_of_first_addr, old_first_addr]
          # Update first addr
          commands << [:stack, :swap]
          commands << [:stack, :dup]
          commands.concat LOAD_TMP_COMMANDS
          # stack: [old_first_addr, addr_of_first_addr, addr_of_first_addr, new_first_addr]
          commands << [:heap, :save]
          commands << [:stack, :swap]
          # stack: [addr_of_first_addr, old_first_addr]
          # Load size
          commands << [:stack, :dup]
          commands << [:stack, :push, 1]
          commands << [:calc, :add]
          commands << [:heap, :load]
          # stack: [addr_of_first_addr, old_first_addr, size]
          # Move old items to new addresses
          commands.concat(times do
            c = []
            c << [:stack, :swap]
            # stack: [addr_of_first_addr, idx, old_target_addr]
            c << [:stack, :dup]
            c.concat LOAD_TMP_COMMANDS
            # stack: [addr_of_first_addr, idx, old_target_addr, old_target_addr, new_target_addr]

            # Update tmp to new_next_addr
            c << [:stack, :dup]
            c << [:stack, :push, 1]
            c << [:calc, :add]
            c.concat SAVE_TMP_COMMANDS
            c << [:stack, :pop]

            # stack: [addr_of_first_addr, idx, old_target_addr, old_target_addr, new_target_addr]
            c << [:stack, :swap]
            c << [:heap, :load]
            # stack: [addr_of_first_addr, idx, old_target_addr, new_target_addr, old_target]
            c << [:heap, :save]
            # stack: [addr_of_first_addr, idx, old_target_addr]
            c << [:stack, :push, 1]
            c << [:calc, :add]
            # stack: [addr_of_first_addr, old_next_addr, idx]
            c << [:stack, :swap]
            c
          end)
          commands << [:stack, :pop] # idx
          commands << [:stack, :pop] # old_next_addr
          commands << [:stack, :pop] # addr_of_first_addr


          commands << [:flow, :end]
          @methods << commands
          label
        )
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

      # stack: [key, hash]
      # return stack: [addr_of_prev_key, addr_of_target_key]
      private def hash_key_to_addr_label
        @hash_key_to_addr_label ||= (
          label = ident_to_label(nil)
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
          commands << [:stack, :push, NONE_ADDR]
          commands << [:stack, :swap]
          # stack: [addr_of_prev_key, addr_of_target_key]

          # Check key equivalent
          commands << [:flow, :def, check_key_equivalent_label]
          commands << [:stack, :dup]
          commands << [:heap, :load]
          commands.concat(LOAD_TMP_COMMANDS)
          # stack: [addr_of_prev_key, addr_of_target_key, target_key, key]
          commands << [:calc, :sub]
          commands << [:flow, :jump_if_zero, key_not_collision_label]
          # stack: [addr_of_prev_key, addr_of_target_key]
          # Check NONE
          commands << [:stack, :dup]
          commands << [:heap, :load]
          commands << [:stack, :push, NONE]
          commands << [:calc, :sub]
          commands << [:flow, :jump_if_zero, key_not_collision_label]

          # stack: [addr_of_prev_key, addr_of_target_key]

          # when collistion
          # pop prev key
          commands << [:stack, :swap]
          commands << [:stack, :pop]
          commands << [:stack, :dup]
          # stack: [addr_of_target_key, addr_of_target_key]
          commands << [:stack, :push, 2]
          commands << [:calc, :add]
          # stack: [addr_of_prev_key, addr_of_next_key_addr]
          commands << [:heap, :load]
          # stack: [addr_of_prev_key, next_key_addr]
          commands << [:stack, :dup]
          commands << [:stack, :push, NONE_ADDR]
          commands << [:calc, :sub]
          commands << [:flow, :jump_if_zero, key_not_collision_label]
          commands << [:flow, :jump, check_key_equivalent_label]

          commands << [:flow, :def, key_not_collision_label]

          commands << [:flow, :end]
          @methods << commands
          label
        )
      end

      # stack: []
      # return stack: [array]
      private def allocate_array_commands(size)
        commands = []

        commands.concat ALLOCATE_HEAP_COMMANDS
        commands << [:stack, :dup]
        commands.concat WRAP_ARRAY_COMMANDS
        commands.concat SAVE_TMP_COMMANDS
        commands << [:stack, :pop]
        # stack: [array_addr_1]

        # Save first addr
        commands << [:stack, :dup]
        commands << [:stack, :push, 3]
        commands << [:calc, :add]
        commands << [:heap, :save]
        # stack: []

        # Allocate size
        commands.concat ALLOCATE_HEAP_COMMANDS
        commands << [:stack, :push, size]
        commands << [:heap, :save]

        # Allocate cap
        cap = ARRAY_FIRST_CAPACITY < size ? size * 2 : ARRAY_FIRST_CAPACITY
        commands.concat ALLOCATE_HEAP_COMMANDS
        commands << [:stack, :push, cap]
        commands << [:heap, :save]

        # Allocate body
        cap.times do
          commands.concat ALLOCATE_HEAP_COMMANDS
          commands << [:stack, :pop]
        end

        commands.concat LOAD_TMP_COMMANDS
        # stack: [array]
      end

      # Array#size
      # stack: []
      # return stack: [int]
      private def define_array_size
        label = ident_to_label(:'Array#size')
        commands = []
        commands << [:flow, :def, label]

        commands.concat load_from_self_commands
        commands.concat UNWRAP_COMMANDS
        commands << [:stack, :push, 1]
        commands << [:calc, :add]
        commands << [:heap, :load]
        commands.concat WRAP_NUMBER_COMMANDS

        commands << [:flow, :end]
        # stack: [size]
        @methods << commands
      end

      # Array#pop
      # stack: []
      # return stack: [obj]
      private def define_array_pop
        label = ident_to_label(:'Array#pop')
        when_empty_label = ident_to_label(nil)
        commands = []
        commands << [:flow, :def, label]

        commands.concat load_from_self_commands
        commands.concat UNWRAP_COMMANDS
        commands << [:stack, :push, 1]
        commands << [:calc, :add]
        commands << [:heap, :load]
        # stack: [size]
        # check empty
        commands << [:stack, :dup]
        commands << [:flow, :jump_if_zero, when_empty_label]

        # when not empty
        # Decrease size
        commands << [:stack, :dup]
        commands.concat load_from_self_commands
        commands.concat UNWRAP_COMMANDS
        commands << [:stack, :push, 1]
        commands << [:calc, :add]
        # stack: [size, size, size_addr]
        commands << [:stack, :swap]
        commands << [:stack, :push, 1]
        commands << [:calc, :sub]
        commands << [:heap, :save]
        # Load item
        commands.concat load_from_self_commands
        commands.concat UNWRAP_COMMANDS
        commands << [:heap, :load]
        # stack: [size, first_addr]
        commands << [:stack, :push, -1]
        commands << [:calc, :add]
        commands << [:calc, :add]
        # stack: [addr_of_target_item]
        commands << [:heap, :load]

        commands << [:flow, :end]
        # stack: [target_item]

        commands << [:flow, :def, when_empty_label]
        commands << [:stack, :pop]
        commands << [:stack, :push, NIL]
        commands << [:flow, :end]
        # stack: [nil]
        @methods << commands
      end

      # Array#push
      # stack: [item]
      # return stack: [self]
      private def define_array_push
        label = ident_to_label(:'Array#push')
        when_realloc_label = ident_to_label(nil)
        when_no_realloc_label = ident_to_label(nil)
        commands = []
        commands << [:flow, :def, label]

        commands.concat load_from_self_commands
        commands.concat(UNWRAP_COMMANDS)
        # stack: [item, addr_of_first_addr]

        # Check realloc necessary
        commands << [:stack, :dup]
        commands << [:stack, :push, 1]
        commands << [:calc, :add]
        # stack: [item, addr_of_first_addr, addr_of_size]
        commands << [:stack, :dup]
        commands << [:stack, :push, 1]
        commands << [:calc, :add]
        # stack: [item, addr_of_first_addr, addr_of_size, addr_of_cap]
        commands << [:heap, :load]
        commands << [:stack, :swap]
        commands << [:heap, :load]
        # stack: [item, addr_of_first_addr, cap, size]
        commands << [:calc, :sub]
        commands << [:flow, :jump_if_zero, when_realloc_label]
        commands << [:flow, :jump, when_no_realloc_label]

        # Realloc
        commands << [:flow, :def, when_realloc_label]
        commands << [:stack, :dup]
        commands << [:flow, :call, realloc_array_label]

        commands << [:flow, :def, when_no_realloc_label]

        # Push
        # stack: [item, addr_of_first_addr]
        commands << [:stack, :dup]
        commands << [:stack, :push, 1]
        commands << [:calc, :add]
        commands << [:heap, :load]
        # stack: [item, addr_of_first_addr, size]
        commands << [:stack, :swap]
        commands << [:heap, :load]
        # stack: [item, size, first_addr]
        commands << [:calc, :add]
        # stack: [item, addr_of_target]
        commands << [:stack, :swap]
        commands << [:heap, :save]

        commands.concat load_from_self_commands
        # Update size
        commands << [:stack, :dup]
        commands.concat UNWRAP_COMMANDS
        # stack: [self, addr_of_first_addr]
        commands << [:stack, :push, 1]
        commands << [:calc, :add]
        commands << [:stack, :dup]
        commands << [:heap, :load]
        # stack: [self, size_addr, size]
        commands << [:stack, :push, 1]
        commands << [:calc, :add]
        commands << [:heap, :save]

        commands << [:flow, :end]
        # stack: [self]
        @methods << commands
      end

      # Array#[]
      # stack: [index]
      # return stack: [item]
      private def define_array_ref
        label = ident_to_label(:'Array#[]')

        commands = []
        commands << [:flow, :def, label]

        commands.concat(UNWRAP_COMMANDS)
        commands.concat load_from_self_commands
        # stack: [index, recv]
        commands.concat(UNWRAP_COMMANDS)
        commands << [:heap, :load]
        # stack: [addr_of_first_item, index]
        commands << [:calc, :add]
        # TODO: range check and return nil
        commands << [:heap, :load]

        commands << [:flow, :end]
        @methods << commands
      end

      # Array#[]=
      # stack: [index, value]
      # return stack: [value]
      private def define_array_attr_asgn
        label = ident_to_label(:'Array#[]=')

        commands = []
        commands << [:flow, :def, label]

        commands << [:stack, :swap]
        # stack: [value, index]
        commands.concat UNWRAP_COMMANDS
        commands.concat load_from_self_commands
        commands.concat(UNWRAP_COMMANDS)
        commands << [:heap, :load]
        # stack: [value, index, first_addr]
        commands << [:calc, :add]
        # TODO: range check and realloc
        commands << [:stack, :swap]
        # stack: [target_addr, value]
        commands.concat SAVE_TMP_COMMANDS
        commands << [:heap, :save]
        commands.concat LOAD_TMP_COMMANDS
        # stack: [value]

        commands << [:flow, :end]
        @methods << commands
      end

      # Hash#[]
      # stack: [key]
      private def define_hash_ref
        label = ident_to_label(:'Hash#[]')
        when_not_found_label = ident_to_label(nil)

        commands = []
        commands << [:flow, :def, label]

        commands.concat load_from_self_commands
        commands << [:flow, :call, hash_key_to_addr_label]
        # stack: [addr_of_prev_key, addr_of_target_key]

        # pop addr_of_prev_key
        commands << [:stack, :swap]
        commands << [:stack, :pop]

        # stack: [addr_of_target_key]
        # check NONE_ADDR (chained)
        commands << [:stack, :dup]
        commands << [:stack, :push, NONE_ADDR]
        commands << [:calc, :sub]
        commands << [:flow, :jump_if_zero, when_not_found_label]

        # check NONE (not chained)
        commands << [:stack, :dup]
        commands << [:heap, :load]
        # stack: [addr_of_target_key, target_key]
        commands << [:stack, :push, NONE]
        commands << [:calc, :sub]
        commands << [:flow, :jump_if_zero, when_not_found_label]

        # when found
        commands << [:stack, :push, 1]
        commands << [:calc, :add]
        # stack: [addr_of_target_value]
        commands << [:heap, :load]

        commands << [:flow, :end]

        # when not found
        commands << [:flow, :def, when_not_found_label]
        commands << [:stack, :pop]
        commands << [:stack, :push, NIL]
        commands << [:flow, :end]
        @methods << commands
      end

      # Hash#[]
      # stack: [key, value]
      private def define_hash_attr_asgn
        label = ident_to_label(:'Hash#[]=')
        when_not_allocated_label = ident_to_label(nil)
        when_allocated_label = ident_to_label(nil)
        after_allocated_label = ident_to_label(nil)

        commands = []
        commands << [:flow, :def, label]

        # stack: [key, value]
        commands << [:stack, :swap]
        commands << [:stack, :dup]
        commands.concat load_from_self_commands
        # stack: [value, key, key, recv]

        commands << [:flow, :call, hash_key_to_addr_label]
        # stack: [value, key, addr_of_prev_key, addr_of_target_key]

        # check NONE_ADDR
        commands << [:stack, :dup]
        commands << [:stack, :push, NONE_ADDR]
        commands << [:calc, :sub]
        commands << [:flow, :jump_if_zero, when_not_allocated_label]
        commands << [:flow, :jump, when_allocated_label]

        # When not allocated
        commands << [:flow, :def, when_not_allocated_label]
        # stack: [value, key, addr_of_prev_key, addr_of_target_key]
        commands << [:stack, :pop]
        commands << [:stack, :push, 2]
        commands << [:calc, :add]
        commands.concat ALLOCATE_NEW_HASH_ITEM_COMMANDS
        # stack: [value, key, addr_of_prev_key, allocated_addr_of_target_key]
        commands.concat SAVE_TMP_COMMANDS
        commands << [:heap, :save]
        commands.concat LOAD_TMP_COMMANDS
        commands << [:flow, :jump, after_allocated_label]

        # When allocated
        commands << [:flow, :def, when_allocated_label]
        # stack: [value, key, addr_of_prev_key, addr_of_target_key]
        commands << [:stack, :swap]
        commands << [:stack, :pop]

        # stack: [value, key, addr_of_target_key]
        commands << [:flow, :def, after_allocated_label]
        # Save key
        commands.concat SAVE_TMP_COMMANDS # addr_of_target_key
        commands << [:stack, :swap]
        commands << [:heap, :save]
        # Save value
        commands.concat LOAD_TMP_COMMANDS # addr_of_target_key
        # stack: [value, addr_of_target_key]
        commands << [:stack, :push, 1]
        commands << [:calc, :add]
        # stack: [value, addr_of_target_value]
        commands.concat SAVE_TMP_COMMANDS # addr_of_target_value
        commands << [:stack, :swap]
        commands.concat LOAD_TMP_COMMANDS # addr_of_target_value
        # stack: [addr_of_target_value, value, addr_of_target_value]
        commands << [:stack, :swap]
        commands.concat SAVE_TMP_COMMANDS # value
        commands << [:heap, :save]
        # stack: [addr_of_target_value]
        # Save addr
        commands << [:stack, :push, 1]
        commands << [:calc, :add]
        # stack: [addr_of_next_key_addr]
        commands << [:stack, :push, NONE_ADDR]
        commands << [:heap, :save]

        commands.concat LOAD_TMP_COMMANDS # value
        commands << [:flow, :end]
        @methods << commands
      end

      # Integer#<=>
      # stack: [right]
      # return stack: [-1/0/1]
      #   if left < rigth  then -1
      #   if left == rigth then 0
      #   if left > rigth then 1
      private def define_op_spaceship
        label = ident_to_label(:'Integer#<=>')
        zero_label = ident_to_label(nil)
        end_label = ident_to_label(nil)
        neg_label = ident_to_label(nil)
        commands = []
        commands << [:flow, :def, label]

        commands.concat load_from_self_commands
        commands << [:calc, :sub]
        commands << [:stack, :dup]
        commands << [:flow, :jump_if_zero, zero_label]

        commands << [:flow, :jump_if_neg, neg_label]

        # if positive
        commands << [:stack, :push, with_type(-1, TYPE_INT)]
        commands << [:flow, :jump, end_label]

        # if negative
        commands << [:flow, :def, neg_label]
        commands << [:stack, :push, with_type(1, TYPE_INT)]
        commands << [:flow, :jump, end_label]

        # if equal
        commands << [:flow, :def, zero_label]
        commands << [:stack, :pop]
        commands << [:stack, :push, with_type(0, TYPE_INT)]

        commands << [:flow, :def, end_label]
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
             # .tap {|index| p [ident, num_to_ws(index).chop]}
        else
          next_label_index
             # .tap { |index| p [caller[2], num_to_ws(index).chop] }
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

      # OPTIMIZE: avoid save NIL for args
      private def update_lvar_commands(table)
        addr_table = table.map do |v|
          variable_name_to_addr(v)
        end
        commands = []
        addr_table.each do |addr|
          commands << [:stack, :push, addr]
          commands << [:stack, :push, NIL]
          commands << [:heap, :save]
        end
        @lvars_stack << addr_table.dup
        lvars << variable_name_to_addr(:self)
        commands
      end
    end
  end
end
