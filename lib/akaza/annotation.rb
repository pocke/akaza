module Akaza
  module Annotation
    using AstExt

    def whitespace(method_name)
      method = instance_method(method_name)
      path = method.source_location[0]
      ast = RubyVM::AbstractSyntaxTree.of(method)

      placeholder = ast.find do |node|
        case node
        in [:COLON2, [:CONST, :Akaza], :Body] then true
        else false
        end
      end

      first_index = ast.scope_args.last_index(path) - ast.first_index(path)
      last_index = -1
      code = ast.to_source(path)[first_index..last_index]
      define_method("__#{method_name}_whitespace") do |input, output|
        Akaza.eval(code, input: input, output: output)
      end

      undef_method method_name
      if placeholder
        original_code = ast.to_source(path)
        s, e = placeholder.first_index(path) - ast.first_index(path), placeholder.last_index(path) - ast.first_index(path)
        original_code[s..e] = "(__#{method_name}_whitespace(input, output))"
        class_eval original_code
      else
        alias_method method_name, "__#{method_name}_whitespace"
      end
    end
  end
end
