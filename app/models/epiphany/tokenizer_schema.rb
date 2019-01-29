require 'active_support/concern'
require 'active_support/inflector'

module Epiphany
  class Tokenizer
    module Schema
      extend ActiveSupport::Concern

      class_methods do
        def phrase_tokenizer_dictionary
          @phrase_tokenizer_dictionary ||= {}
        end

        def all_entity_types
          @all_entity_types ||= (default_entity_types + custom_entity_types.values.compact)
        end

        def text_match_entity_types
          @text_match_entity_types ||= all_entity_types.select{|e| e.validation_type == 'text_match'}
        end

        def custom_analyzer_entity_types
          @custom_analyzer_entity_types ||= custom_entity_types.values.compact
        end

        def intent_types
          @_intent_types ||= default_intent_types | custom_intents.values
        end

        #
        # This module is used to boot load a ~json ~schema
        #
        # Epiphany::Tokenizer has a class method to define specific entity_types or intent_types
        # which exists in the Epiphany Open Source Library
        #
        # If left blank it will grab all of the  default
        # entity_types and intent_types in the Epiphany Open Source Library
        # which are all located at:
        # lib/epiphany/entity_types/*.json
        # lib/epiphany/intent_types/*.json
        #
        # Otherwise you can specify the specific files in the library you want.
        # example:
        #
        # class SampleTokenizer < Epiphany::Tokenizer
        #   default_intent_types :track_exercise
        #   default_entity_types :exercise, :metric, :weighted_lift
        # end
        #
        def default_entity_types(*args)
          @_dictionary_entities ||= file_paths_for('entity_types', args).map do |path|
            data = JSON.parse(File.read(path))
            EntityType.new(path, data)
          end
        end

        def default_intent_types(*args)
          @_dictionary_intents ||= file_paths_for('intent_types', args).map do |path|
            data = JSON.parse(File.read(path))
            intent_type = data.keys.first
            data.merge! data[intent_type]
            data[:type] = intent_type
            IntentType.new(path, data)
          end
        end

        def file_paths_for(type, names)
          if names.length > 1
            names.flatten.map do |name|
              Dir[File.join(Dir.pwd, 'lib', 'epiphany', type, "#{name}.json")]
            end.flatten
          else
            Dir[File.join(Dir.pwd, 'lib', 'epiphany', type, "*.json")]
          end
        end

        #
        # You can also include intents and entities that are custom to your use case
        # via the custom_entity, and custom_intent class methods
        # both methods require a name and conf_directory
        # conf_directory should contain .json files that meet the
        # Epiphany entity_type.json, intent_type.json specs
        # please see #TODO add resource link for json specs for more information
        # example:
        #
        # class SampleTokenizer < Epiphany::Tokenizer
        #   custom_entity name: :my_special_topic, conf_directory: "#{Dir.pwd}/custom_entities/" # can be anywhere
        #   custom_intent :search_twitter, conf_directory: "#{Dir.pwd}/custom_intents/" # can be anywhere
        # end
        #
        def custom_entity(**args)
          name, conf_file = validate_custom_args(args)
          Epiphany::Config.custom_analyzers << EntityType.new(name, conf_file)
        end

        def custom_intent(**args)
          name, conf_file = validate_custom_args(args)
          conf_file.merge! conf_file[conf_file['type']]
          custom_intents[name] = IntentType.new(name, conf_file)
        end

        def validate_custom_args(args)
          filepath = args[:conf_filepath] || args[:conf_file_path]
          raise ArgumentError.new("name: is required for Tokenizer custom_entity.") unless args[:name]
          raise ArgumentError.new("conf_filepath: is required for Tokenizer custom_entity.") unless filepath
          raise ArgumentError.new("conf_filepath: #{filepath} : ERROR - provided conf file does not exists") unless File.file?(filepath)
          conf = JSON.parse(File.read(filepath))
          conf.merge! "type" => args[:name].to_s
          [args[:name], conf]
        end

        # TODO should we throw an exception if some tries to add to an "existing" key?
        # if not it'll override the previous config and we probably should throw an error
        # telling them they need to rename / resolve it however they seem fit.
        def custom_entity_types
          @_custom_entity_types ||= {}
        end

        def custom_intents
          @_custom_intents ||= {}
        end

        def get_custom_analyzers
          @custom_entity_analyzers ||= custom_entity_types.values
        end

        #
        # custom_entity_type_by_callback & custom_intent_type_by_callback
        # Epiphany lib does not force you to create json files
        # this custom callback feature allows you to define your entity or intent
        # dynamically from your own rules
        # #TODO add resource link
        # required params:
        # example:
        #
        def custom_entity_type_and_analyzer(**args)
          validate_entity_analyzer_args(args)
          custom_entity_types[args[:type]] = EntityType.new(args[:type], args)
        end

        def custom_intent_type_by_callback(**args)
          validate_intent_callback_args(args)
          custom_intents[args[:type]] = IntentType.new(args[:type], args)
        end

        def validate_entity_analyzer_args(args)
          raise ArgumentError.new("entity_name: is required for Tokenizer custom entity callback.") unless args[:entity_name]
          raise ArgumentError.new("entity_name: must be a symbol Tokenizer custom entity callback.") unless args[:entity_name].is_a? Symbol
          raise ArgumentError.new("custom_analyzer: is required for Tokenizer custom entity type analyzer.") unless args[:custom_analyzer]
          raise ArgumentError.new("custom_analyzer: must be a subclass of Epiphany::Phrase::CustomAnalyzer") unless args[:custom_analyzer].superclass == Epiphany::CustomAnalyzer
          args[:type] = args[:entity_name].to_s
          args[:validation_type] = "custom_analyzer"
          args
        end

        def validate_intent_callback_args(args)
          raise ArgumentError.new("intent_name: is required for Tokenizer custom intent callback.") unless args[:intent_name]
          raise ArgumentError.new("intent_name: must be a symbol Tokenizer custom intent callback.") unless args[:intent_name].is_a? Symbol
          raise ArgumentError.new("required_entities: [:some_entity] is required for Tokenizer custom intent callback.") unless args[:required_entities]
          args[:type] = args[:intent_name].to_s
          args
        end

        #end class methods - code comments make this look bigger than what it really is
      end

      #TODO add validators to these classes, and maybe move these classes somewhere else?
      class EntityType
        attr_reader :type, :validation_type, :known_phrases, :required_entities, :custom_analyzer

        def initialize(filepath, args)
          @type = args["type"] || args[:type] || filepath.match(/(\w+)(.json)/i)[0].gsub('.json','')
          @validation_type = args["validation_type"] || args[:validation_type]
          @known_phrases = args["known_phrases"] || args[:known_phrases] || []
          @required_entities = args["required_entities"] || args[:required_entities] || []
          @custom_analyzer = args["custom_analyzer"] || args[:custom_analyzer]
          @type.freeze
          @validation_type.freeze
          @known_phrases.freeze
          @required_entities.freeze
          @custom_analyzer.freeze
        end

        def phrases_for_validation
          @phrases_for_validation ||= known_phrases.map do |phrase|
            p = phrase.downcase
            [p.singularize, p, p.pluralize]
          end.flatten.compact.uniq
        end
      end

      class IntentType
        attr_accessor :type, :optional_entities, :required_entities, :keywords_boost

        def initialize(filepath, args)
          @type = args["type"] || args[:type] || filepath.match(/(\w+)(.json)/i)[0].gsub('.json','')
          @required_entities = args['required_entities'] || args[:required_entities] || []
          @optional_entities = args['optional_entities'] || args[:optional_entities] || []
          @keywords_boost = args[:keywords_boost] || args['keywords_boost'] || []
        end
      end
    end
  end
end
