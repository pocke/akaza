module Akaza
  module Annotation
    using AstExt

    def whitespace(method_name)
      method = instance_method(method_name)
      path = method.source_location[0]
      ast = RubyVM::AbstractSyntaxTree.of(method)
      first_index = ast.scope_args.last_index(path) - ast.first_index(path)
      last_index = -1
      code = ast.to_source(path)[first_index..last_index]

      undef_method method_name
      define_method(method_name) do |input, output|
        Akaza.eval(code, input: input, output: output)
      end
    end
  end
end
