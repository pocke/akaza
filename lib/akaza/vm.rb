module Akaza
  class VM
    def initialize(commands, input, output)
      @commands = commands
      @input = input
      @output = output
      @stack = []
      @heap = {}
      @call_stack = []
      @index = 0
      @labels = {}

      prepare_label
    end

    def eval
      while true
        # p @stack
        # p @heap
        # puts '-' * 100
        # p @commands[@index]
        case @commands[@index]
        in [:stack_push, number]
          @stack.push number
        in [:stack_dup]
          @stack.push @stack.last
        in [:stack_swap]
          @stack[-1], @stack[-2] = @stack[-2], @stack[-1]
        in [:stack_pop]
          @stack.pop
        in [:calc_add]
          @stack[-2] = @stack[-2] + @stack[-1]
          @stack.pop
        in [:calc_sub]
          @stack[-2] = @stack[-2] - @stack[-1]
          @stack.pop
        in [:calc_multi]
          @stack[-2] = @stack[-2] * @stack[-1]
          @stack.pop
        in [:calc_div]
          @stack[-2] = @stack[-2] / @stack[-1]
          @stack.pop
        in [:calc_mod]
          @stack[-2] = @stack[-2] % @stack[-1]
          @stack.pop
        in [:heap_save]
          val = @stack.pop
          addr = @stack.pop
          @heap[addr] = val
        in [:heap_load]
          val = @heap[@stack[-1]]
          raise "Heap #{addr} is not initialized" unless val
          @stack[-1] = val
        in [:flow_def, label]
          # skip
        in [:flow_call, label]
          raise "unknwon label:#{label.inspect}" unless @labels.key?(label)
          @call_stack.push @index
          @index = @labels[label]
        in [:flow_jump, label]
          raise "unknwon label:#{label.inspect}" unless @labels.key?(label)
          @index = @labels[label]
        in [:flow_jump_if_zero, label]
          @index = @labels[label] if @stack.pop == 0
        in [:flow_jump_if_neg, label]
          @index = @labels[label] if @stack.pop < 0
        in [:flow_end]
          @index = @call_stack.pop
        in [:flow_exit]
          return
        in [:io_write_char]
          @output.write @stack.pop.chr
        in [:io_write_num]
          @output.write @stack.pop.to_s
        in [:io_read_char]
          addr = @stack.pop
          @heap[addr] = @input.read(1).ord
        in [:io_read_num]
          addr = @stack.pop
          @heap[addr] = @input.readline.to_i
        end
        @index += 1
      end
    end

    def prepare_label
      @commands.each.with_index do |command, index|
        case command
        in [:flow_def, label]
          @labels[label] = index
        else
          # skip
        end
      end
    end
  end
end
