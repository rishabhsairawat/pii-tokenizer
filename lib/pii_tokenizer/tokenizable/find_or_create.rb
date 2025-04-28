require 'active_support/concern'

module PiiTokenizer
  module Tokenizable
    module FindOrCreate
      extend ActiveSupport::Concern

      class_methods do
        # Method to find by tokenized fields or create
        def find_or_create_by(attributes)
          find_by(attributes) || create(attributes)
        end

        # Method to find by tokenized fields or initialize
        def find_or_initialize_by(attributes)
          find_by(attributes) || new(attributes)
        end
      end
    end
  end
end 