module Akaza
  module AstExt
    refine RubyVM::AbstractSyntaxTree::Node do
      def to_source(path)
        file_content(path)[first_index(path)..last_index(path)]
      end

      def traverse(&on_enter)
        opt = {}
        on_enter.call self, opt
        unless opt[:skip_children]
          children.each do |child|
            child.traverse(&on_enter) if child.is_a?(RubyVM::AbstractSyntaxTree::Node)
          end
        end
      end

      def find(&block)
        traverse do |node|
          return node if block.call(node)
        end
        nil
      end

      def deconstruct
        [type, *children]
      end

      # method node ext

      def scope_body
        children[2]
      end

      def scope_args
        children[1]
      end

      def first_index(path)
        return first_column if first_lineno == 1

        lines = file_content(path).split("\n")
        lines[0..(first_lineno - 2)].sum(&:size) +
          first_lineno - 1 + # For \n
          first_column
      end

      def last_index(path)
        last_column = self.last_column - 1
        return last_column if last_lineno == 1

        lines = file_content(path).split("\n")
        lines[0..(last_lineno - 2)].sum(&:size) +
          last_lineno - 1 + # For \n
          last_column
      end

      private def file_content(path)
        @file_content ||= {}
        @file_content[path] ||= File.binread(path)
      end
    end
  end
end
