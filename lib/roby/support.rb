require 'active_support/core_ext/string/inflections'

class String
    include ActiveSupport::CoreExtensions::String::Inflections
end

class Object
    # Get the singleton class for this object
    def singleton_class
        class << self; self; end
    end
end


class Module
    # Check if +klass+ is an ancestor of this class/module
    def has_ancestor?(klass); ancestors.find { |a| a == klass } end

    alias :__instance_include__  :include
    # Includes a module in this one, with singleton class inclusion
    # If a module defines a ClassExtension submodule, then 
    # the module itself is included normally, and ClassExtension 
    # is included in the target singleton class
    def include(mod)
        __instance_include__ mod
        begin
            extend mod.const_get(:ClassExtension)
        rescue NameError
        end
    end
end

module Kernel
    # Validates an option hash, with default value support
    # 
    # :call-seq:
    #   validate_options(option, hash)       -> options
    #   validate_options(option, array)
    #   validate_options(nil, known_options)
    #
    # In the first form, +option_hash+ should contain keys which are also 
    # in known_hash. The non-nil values of +known_hash+ are used as default
    # values
    #
    # In the second form, +known_array+ is an array of option
    # keys. +option_hash+ keys shall be in +known_array+
    #
    # +nil+ is treated as an option hash
    #
    # All option keys are converted into symbols
    #
    def validate_options(options, known_options)
        options = Hash.new unless options
       
        if Array === known_options
            # Build a hash with all values to nil
            known_options = known_options.inject({}) { |h, k| h[k.to_sym] = nil; h }
        end

        options        = options.inject({}) { |h,v| h[v[0].to_sym] = v[1]; h }
        known_options  = known_options.inject({}) { |h,v| h[v[0].to_sym] = v[1]; h }

        not_valid = options.keys - known_options.keys
        not_valid = not_valid.map { |m| "'#{m}'" }.join(" ")
        raise ArgumentError, "unknown options #{not_valid}" if !not_valid.empty?

        # Set default values defined in 'known_options'
        known_options.each_key do |k| 
            value = known_options[k]
            options[k] ||= value unless value.nil?
        end

        options
    end
end


