# typed: strict
# frozen_string_literal: true

module Yogurt
  class CodeGenerator
    extend T::Sig
    include Utils

    PROTECTED_NAMES = T.let([
      *Object.instance_methods,
      *Yogurt::QueryResult.instance_methods,
      *Yogurt::ErrorResult.instance_methods
    ].map(&:to_s).sort.uniq.freeze, T::Array[String])

    sig {returns(T::Hash[String, DefinedClass])}
    attr_reader :classes

    sig {params(schema: GRAPHQL_SCHEMA, generated_code_module: Module).void}
    def initialize(schema, generated_code_module)
      @schema = T.let(schema, GRAPHQL_SCHEMA)
      @generated_code_module = T.let(generated_code_module, Module)

      # Maps GraphQL enum name to class name
      @enums = T.let({}, T::Hash[String, String])

      # Maps GraphQL input type name to class name
      @input_types = T.let({}, T::Hash[String, String])
      @scalars = T.let(Yogurt.scalar_converters(schema), T::Hash[String, SCALAR_CONVERTER])
      @classes = T.let({}, T::Hash[String, DefinedClass])
    end

    # Returns the contents of the generated classes, in dependency order, as a single file.
    sig {returns(String)}
    def contents
      definitions = DefinedClassSorter.new(classes.values)
        .sorted_classes
        .map(&:to_ruby)
        .join("\n")

      <<~STRING
        # typed: strict
        # frozen_string_literal: true

        #{definitions}
      STRING
    end

    # Returns the contents of the generated classes, split into separate files (one per class).
    # Classes are returned in dependency order.
    sig {returns(T::Array[GeneratedFile])}
    def content_files
      DefinedClassSorter.new(classes.values).sorted_classes.map do |klass|
        GeneratedFile.new(
          constant_name: klass.name,
          dependencies: klass.dependencies,
          code: klass.to_ruby,
          type: case klass
          when RootClass
            GeneratedFile::FileType::OPERATION
          when LeafClass
            GeneratedFile::FileType::OBJECT_RESULT
          when InputClass
            GeneratedFile::FileType::INPUT_OBJECT
          when EnumClass
            GeneratedFile::FileType::ENUM
          else
            raise "Unhandled class type: #{klass.inspect}"
          end,
        )
      end
    end

    # Returns the contents with syntax highlighting (if CodeRay is available)
    sig {returns(String)}
    def formatted_contents
      if defined?(CodeRay)
        CodeRay.scan(contents, :ruby).term
      else
        contents
      end
    end

    sig {params(declaration: QueryDeclaration).void}
    def generate(declaration)
      query = GraphQL::Query.new(declaration.schema, declaration.query_text)

      query.operations.each do |name, op_def|
        owner_type = case op_def.operation_type
        when 'query'
          schema.query
        when 'mutation'
          schema.mutation
        when 'subscription'
          schema.subscription
        else
          Kernel.raise("Unknown operation type: #{op_def.type}")
        end

        ensure_constant_name(name)
        module_name = "::#{declaration.container.name}::#{name}"
        generate_result_class(
          module_name,
          owner_type,
          op_def.selections,
          operation_declaration: OperationDeclaration.new(
            declaration: declaration,
            operation_name: name,
            variables: op_def.variables,
          ),
        )
      end
    end

    sig {params(definition: DefinedClass).void}
    def add_class(definition)
      raise "Attempting to redefine class #{definition.name}" if @classes.key?(definition.name)

      @classes[definition.name] = definition
    end

    sig {returns(GRAPHQL_SCHEMA)}
    def schema
      @schema
    end

    sig {params(name: String).void}
    def ensure_constant_name(name)
      return if name.match?(/\A[A-Z][a-zA-Z0-9_]+\z/)

      raise "You must use valid Ruby constant names for query names (got #{name})"
    end

    sig {params(enum_type: T.class_of(GraphQL::Schema::Enum)).returns(String)}
    def enum_class(enum_type)
      enum_class_name = @enums[enum_type.graphql_name]
      return enum_class_name if enum_class_name

      klass_name = "::#{@generated_code_module.name}::#{enum_type.graphql_name}"
      add_class(EnumClass.new(name: klass_name, serialized_values: enum_type.values.keys))
      @enums[enum_type.graphql_name] = klass_name
    end

    sig {params(graphql_name: String).returns(String)}
    def input_class(graphql_name)
      input_class_name = @input_types[graphql_name]
      return input_class_name if input_class_name

      klass_name = "::#{schema.name}::#{graphql_name}"
      graphql_type = schema.types[graphql_name]

      arguments = graphql_type.arguments.each_value.map do |argument|
        variable_definition(argument)
      end

      add_class(InputClass.new(name: klass_name, arguments: arguments))
      @input_types[graphql_name] = klass_name
    end

    sig do
      params(
        module_name: String,
        owner_type: T.untyped,
        selections: T::Array[T.untyped],
        operation_declaration: T.nilable(OperationDeclaration),
        dependencies: T::Array[String],
      )
        .returns(TypedOutput)
    end
    private def generate_result_class(module_name, owner_type, selections, operation_declaration: nil, dependencies: [])
      methods = T.let({}, T::Hash[Symbol, T::Array[FieldAccessPath]])
      next_dependencies = [module_name, *dependencies]

      generate_methods_from_selections(
        module_name: module_name,
        owner_type: owner_type,
        parent_types: [owner_type],
        selections: selections,
        methods: methods,
        next_dependencies: next_dependencies,
      )

      defined_methods = methods.map do |name, paths|
        FieldAccessMethod.new(
          name: name,
          field_access_paths: paths,
          schema: schema,
        )
      end

      if operation_declaration
        variable_definitions = operation_declaration.variables.map {|v| variable_definition(v)}
        variable_dependencies = variable_definitions.map(&:dependency).compact
        add_class(
          RootClass.new(
            name: module_name,
            schema: schema,
            operation_name: operation_declaration.operation_name,
            graphql_type: owner_type,
            query_container: operation_declaration.declaration.container,
            defined_methods: defined_methods,
            variables: variable_definitions,
            dependencies: dependencies + variable_dependencies,
          ),
        )
      else
        klass_definition = @classes[module_name]
        if klass_definition.nil?
          add_class(
            LeafClass.new(
              name: module_name,
              schema: schema,
              defined_methods: defined_methods,
              dependencies: dependencies,
              graphql_type: owner_type,
            ),
          )
        elsif klass_definition.is_a?(LeafClass)
          raise "Attempting to extend existing class with a different owner type: #{klass_definition.graphql_type.graphql_name} vs #{owner_type.graphql_name}" if klass_definition.graphql_type != owner_type

          klass_definition.merge_defined_methods(defined_methods)
          klass_definition.dependencies |= dependencies
        else
          raise "Attempting to extend a class that is intended to be an object result class, but found the wrong type: #{klass_definition.inspect}"
        end
      end

      TypedOutput.new(
        signature: module_name,
        deserializer: <<~STRING,
          #{module_name}.new(raw_value)
        STRING
      )
    end

    sig do
      params(
        module_name: String,
        owner_type: T.untyped,
        parent_types: T::Array[T.untyped],
        selections: T::Array[T.untyped],
        methods: T::Hash[Symbol, T::Array[FieldAccessPath]],
        next_dependencies: T::Array[String],
      ).void
    end
    private def generate_methods_from_selections(module_name:, owner_type:, parent_types:, selections:, methods:, next_dependencies:)
      # First pass, handle the fields that are directly selected.
      selections.each do |node|
        next unless node.is_a?(GraphQL::Language::Nodes::Field)

        # Get the result type for this particular selection
        field_name = node.name

        # We always include a `__typename` method on query result objects,
        # so it's redundant here.
        next if field_name == '__typename' && node.alias.nil?

        field_definition = owner_type.get_field(field_name)

        if field_definition.nil?
          field_definition = if owner_type == schema.query && (entry_point_field = schema.introspection_system.entry_point(name: field_name))
            entry_point_field
          elsif (dynamic_field = schema.introspection_system.dynamic_field(name: field_name))
            dynamic_field
          else
            raise "Invariant: no field for #{owner_type}.#{field_name}"
          end
        end

        input_name = node.alias || node.name
        next_name = if node.alias
          "#{module_name}::#{camelize(node.alias)}_#{camelize(node.name)}"
        else
          "#{module_name}::#{camelize(input_name)}"
        end
        return_type = generate_output_type(
          field_definition.type,
          node.selections,
          next_name,
          input_name,
          next_dependencies,
        )

        method_name = generate_method_name(underscore(input_name))
        method_array = methods[method_name] ||= T.let([], T::Array[FieldAccessPath])
        method_array << FieldAccessPath.new(
          name: method_name,
          schema: schema,
          signature: return_type.signature,
          expression: return_type.deserializer,
          fragment_types: parent_types.map(&:graphql_name),
        )
      end

      # Second pass, handle fragment spreads
      selections.each do |node| # rubocop:disable Style/CombinableLoops
        next unless node.is_a?(GraphQL::Language::Nodes::InlineFragment)

        subselections = node.selections
        fragment_type = schema.types[node.type.name]
        fragment_methods = {}

        generate_methods_from_selections(
          module_name: module_name,
          owner_type: fragment_type,
          parent_types: [*parent_types, fragment_type],
          selections: subselections,
          methods: fragment_methods,
          next_dependencies: next_dependencies,
        )

        fragment_methods.each do |method_name, submethods|
          method_array = methods[method_name] ||= T.let([], T::Array[FieldAccessPath])
          method_array.concat(submethods)
        end
      end
    end

    sig do
      params(
        wrappers: T::Array[TypeWrapper],
        variable_name: String,
        array_wrappers: Integer,
        level: Integer,
        core_expression: String,
      ).returns(String)
    end
    def build_expression(wrappers, variable_name, array_wrappers, level, core_expression)
      next_wrapper = wrappers.shift
      case next_wrapper
      when TypeWrapper::ARRAY
        array_wrappers -= 1
        next_variable_name = if array_wrappers.zero?
          "raw_value"
        else
          "inner_value#{array_wrappers}"
        end

        indent(<<~STRING.rstrip, level.positive? ? 1 : 0)
          #{variable_name}.map do |#{next_variable_name}|
          #{indent(build_expression(wrappers, next_variable_name, array_wrappers, level + 1, core_expression), 1)}
          end
        STRING
      when TypeWrapper::NILABLE
        break_word = level.zero? ? 'return' : 'next'
        <<~STRING.rstrip
          #{break_word} if #{variable_name}.nil?
          #{build_expression(wrappers, variable_name, array_wrappers, level, core_expression)}
        STRING
      when nil
        if level.zero?
          core_expression.gsub(/raw_value/, variable_name)
        else
          core_expression
        end
      else
        T.absurd(next_wrapper)
      end
    end

    # Returns the TypedOutput object for this graphql type.
    sig do
      params(
        graphql_type: T.untyped,
        subselections: T::Array[T.untyped],
        next_module_name: String,
        input_name: String,
        dependencies: T::Array[String],
      ).returns(TypedOutput)
    end
    def generate_output_type(graphql_type, subselections, next_module_name, input_name, dependencies)
      # Unwrap the graphql type, but keep track of the wrappers that it had
      # so that we can build the sorbet signature and return expression.
      wrappers = T.let([], T::Array[TypeWrapper])
      fully_unwrapped_type = T.let(graphql_type, T.untyped)

      # Sorbet uses nullable wrappers, whereas GraphQL uses non-nullable wrappers.
      # This boolean is used to help with the conversion.
      skip_nilable = T.let(false, T::Boolean)
      array_wrappers = 0

      loop do
        if fully_unwrapped_type.non_null?
          fully_unwrapped_type = T.unsafe(fully_unwrapped_type).of_type
          skip_nilable = true
          next
        end

        wrappers << TypeWrapper::NILABLE if !skip_nilable
        skip_nilable = false

        if fully_unwrapped_type.list?
          wrappers << TypeWrapper::ARRAY
          array_wrappers += 1
          fully_unwrapped_type = T.unsafe(fully_unwrapped_type).of_type
          next
        end

        break
      end

      core_typed_expression = unwrapped_graphql_type_to_output_type(fully_unwrapped_type, subselections, next_module_name, dependencies)

      signature = core_typed_expression.signature
      variable_name = "raw_result[#{input_name.inspect}]"
      method_body = build_expression(wrappers.dup, variable_name, array_wrappers, 0, core_typed_expression.deserializer)

      wrappers.reverse_each do |wrapper|
        case wrapper
        when TypeWrapper::ARRAY
          signature = "T::Array[#{signature}]"
        when TypeWrapper::NILABLE
          signature = "T.nilable(#{signature})"
        else
          T.absurd(wrapper)
        end
      end

      TypedOutput.new(
        signature: signature,
        deserializer: method_body,
      )
    end

    sig {params(scalar_converter: SCALAR_CONVERTER).returns(TypedOutput)}
    def output_type_from_scalar_converter(scalar_converter)
      name = scalar_converter.name
      raise "Expected scalar deserializer to be assigned to a constant" if name.nil?

      TypedOutput.new(
        signature: scalar_converter.type_alias.name,
        deserializer: "#{name}.deserialize(raw_value)",
      )
    end

    sig do
      params(
        type_name: String,
        block: T.proc.returns(TypedOutput),
      ).returns(TypedOutput)
    end
    def deserializer_or_default(type_name, &block)
      deserializer = @scalars[type_name]
      return output_type_from_scalar_converter(deserializer) if deserializer

      yield
    end

    # Given an (unwrapped) GraphQL type, returns the definition for the type to use
    # for the signature and method body.
    sig do
      params(
        graphql_type: T.untyped,
        subselections: T::Array[T.untyped],
        next_module_name: String,
        dependencies: T::Array[String],
      ).returns(TypedOutput)
    end
    def unwrapped_graphql_type_to_output_type(graphql_type, subselections, next_module_name, dependencies)
      # TODO: Once https://github.com/sorbet/sorbet/issues/649 is fixed, change the `cast`'s back to `let`'s
      if graphql_type == GraphQL::Types::Boolean
        TypedOutput.new(
          signature: "T::Boolean",
          deserializer: 'T.cast(raw_value, T::Boolean)',
        )
      elsif graphql_type == GraphQL::Types::BigInt
        deserializer_or_default(T.unsafe(GraphQL::Types::BigInt).graphql_name) do
          TypedOutput.new(
            signature: "Integer",
            deserializer: 'T.cast(raw_value, T.any(String, Integer)).to_i',
          )
        end
      elsif graphql_type == GraphQL::Types::ID
        deserializer_or_default('ID') do
          TypedOutput.new(
            signature: "String",
            deserializer: 'T.cast(raw_value, String)',
          )
        end
      elsif graphql_type == GraphQL::Types::ISO8601Date
        deserializer_or_default(T.unsafe(GraphQL::Types::ISO8601Date).graphql_name) do
          output_type_from_scalar_converter(Converters::Date)
        end
      elsif graphql_type == GraphQL::Types::ISO8601DateTime
        deserializer_or_default(T.unsafe(GraphQL::Types::ISO8601DateTime).graphql_name) do
          output_type_from_scalar_converter(Converters::Time)
        end
      elsif graphql_type == GraphQL::Types::Int
        TypedOutput.new(
          signature: "Integer",
          deserializer: 'T.cast(raw_value, Integer)',
        )
      elsif graphql_type == GraphQL::Types::Float
        TypedOutput.new(
          signature: "Float",
          deserializer: 'T.cast(raw_value, Float)',
        )
      elsif graphql_type == GraphQL::Types::String
        TypedOutput.new(
          signature: "String",
          deserializer: 'T.cast(raw_value, String)',
        )
      else
        type_kind = graphql_type.kind
        if type_kind.enum?
          klass_name = enum_class(graphql_type)
          dependencies.push(klass_name)

          TypedOutput.new(
            signature: klass_name,
            deserializer: "#{klass_name}.deserialize(raw_value)",
          )
        elsif type_kind.scalar?
          deserializer_or_default(graphql_type.graphql_name) do
            TypedOutput.new(
              signature: T.unsafe(Yogurt::SCALAR_TYPE).name,
              deserializer: "T.cast(raw_value, #{T.unsafe(Yogurt::SCALAR_TYPE).name})",
            )
          end
        elsif type_kind.composite?
          generate_result_class(
            next_module_name,
            graphql_type,
            subselections,
            dependencies: dependencies,
          )
        else
          raise "Unknown GraphQL type kind: #{graphql_type.graphql_name} (#{graphql_type.kind.inspect})"
        end
      end
    end

    sig {params(variable: T.any(GraphQL::Language::Nodes::VariableDefinition, GraphQL::Schema::Argument)).returns(VariableDefinition)}
    def variable_definition(variable)
      wrappers = T.let([], T::Array[TypeWrapper])
      fully_unwrapped_type = T.let(variable.type, T.untyped)

      skip_nilable = T.let(false, T::Boolean)
      array_wrappers = 0

      loop do
        non_null = fully_unwrapped_type.is_a?(GraphQL::Schema::NonNull) || fully_unwrapped_type.is_a?(GraphQL::Language::Nodes::NonNullType)
        if non_null
          fully_unwrapped_type = T.unsafe(fully_unwrapped_type).of_type
          skip_nilable = true
          next
        end

        wrappers << TypeWrapper::NILABLE if !skip_nilable
        skip_nilable = false

        list = fully_unwrapped_type.is_a?(GraphQL::Schema::List) || fully_unwrapped_type.is_a?(GraphQL::Language::Nodes::ListType)
        if list
          wrappers << TypeWrapper::ARRAY
          array_wrappers += 1
          fully_unwrapped_type = T.unsafe(fully_unwrapped_type).of_type
          next
        end

        break
      end

      core_input_type = unwrapped_graphql_type_to_input_type(fully_unwrapped_type)
      variable_name = underscore(variable.name).to_sym
      signature = core_input_type.signature
      serializer = core_input_type.serializer

      wrappers.reverse_each do |wrapper|
        case wrapper
        when TypeWrapper::NILABLE
          signature = "T.nilable(#{signature})"
          serializer = <<~STRING
            if raw_value
              #{indent(serializer, 1).strip}
            end
          STRING
        when TypeWrapper::ARRAY
          signature = "T::Array[#{signature}]"
          intermediate_name = "#{variable_name}#{array_wrappers}"
          serializer = serializer.gsub(/\braw_value\b/, intermediate_name)
          serializer = <<~STRING
            raw_value.map do |#{intermediate_name}|
              #{indent(serializer, 1).strip}
            end
          STRING
        else
          T.absurd(wrapper)
        end
      end

      serializer = serializer.gsub(/\braw_value\b/, variable_name.to_s)

      VariableDefinition.new(
        name: variable_name,
        graphql_name: variable.name,
        signature: signature,
        serializer: serializer.strip,
        dependency: core_input_type.dependency,
      )
    end

    sig {params(scalar_converter: SCALAR_CONVERTER).returns(TypedInput)}
    def input_type_from_scalar_converter(scalar_converter)
      name = scalar_converter.name
      raise "Expected scalar deserializer to be assigned to a constant" if name.nil?

      TypedInput.new(
        signature: scalar_converter.type_alias.name,
        serializer: "#{name}.serialize(raw_value)",
      )
    end

    sig do
      params(
        type_name: String,
        block: T.proc.returns(TypedInput),
      ).returns(TypedInput)
    end
    def serializer_or_default(type_name, &block)
      deserializer = @scalars[type_name]
      return input_type_from_scalar_converter(deserializer) if deserializer

      yield
    end

    sig do
      params(graphql_type: T.untyped).returns(TypedInput)
    end
    def unwrapped_graphql_type_to_input_type(graphql_type)
      graphql_type = schema.types[T.unsafe(graphql_type).name] if graphql_type.is_a?(GraphQL::Language::Nodes::TypeName)

      if graphql_type == GraphQL::Types::Boolean
        TypedInput.new(
          signature: "T::Boolean",
          serializer: "raw_value",
        )
      elsif graphql_type == GraphQL::Types::BigInt
        serializer_or_default(T.unsafe(GraphQL::Types::BigInt).graphql_name) do
          TypedInput.new(
            signature: "Integer",
            serializer: "raw_value",
          )
        end
      elsif graphql_type == GraphQL::Types::ID
        serializer_or_default('ID') do
          TypedInput.new(
            signature: "String",
            serializer: "raw_value",
          )
        end
      elsif graphql_type == GraphQL::Types::ISO8601Date
        serializer_or_default(T.unsafe(GraphQL::Types::ISO8601Date).graphql_name) do
          input_type_from_scalar_converter(Converters::Date)
        end
      elsif graphql_type == GraphQL::Types::ISO8601DateTime
        serializer_or_default(T.unsafe(GraphQL::Types::ISO8601DateTime).graphql_name) do
          input_type_from_scalar_converter(Converters::Time)
        end
      elsif graphql_type == GraphQL::Types::Int
        TypedInput.new(
          signature: "Integer",
          serializer: "raw_value",
        )
      elsif graphql_type == GraphQL::Types::Float
        TypedInput.new(
          signature: "Float",
          serializer: "raw_value",
        )
      elsif graphql_type == GraphQL::Types::String
        TypedInput.new(
          signature: "String",
          serializer: "raw_value",
        )
      elsif graphql_type.is_a?(Class)
        if graphql_type < GraphQL::Schema::Enum
          klass_name = enum_class(graphql_type)

          TypedInput.new(
            signature: klass_name,
            serializer: "raw_value.serialize",
            dependency: klass_name,
          )
        elsif graphql_type < GraphQL::Schema::Scalar
          serializer_or_default(graphql_type.graphql_name) do
            TypedInput.new(
              signature: T.unsafe(Yogurt::SCALAR_TYPE).name,
              serializer: "raw_value",
            )
          end
        elsif graphql_type < GraphQL::Schema::InputObject
          klass_name = input_class(T.unsafe(graphql_type).graphql_name)
          TypedInput.new(
            signature: klass_name,
            serializer: "raw_value.serialize",
            dependency: klass_name,
          )
        else
          raise "Unknown GraphQL type: #{graphql_type.inspect}"
        end
      else
        raise "Unknown GraphQL type: #{graphql_type.inspect}"
      end
    end
  end
end
