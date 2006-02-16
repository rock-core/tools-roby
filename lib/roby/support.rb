require 'active_support/core_ext/string/inflections'
require 'enumerator'
require 'thread'

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

    # Defines a new constant under a given module
    # :call-seq:
    #   define_under(name, value)   ->              value
    #   define_under(name) { ... }  ->              value
    #
    # In the first form, the method gets its value from its argument. 
    # In the second case, it calls the provided block
    def define_under(name, value = nil)
        begin
            curdef = const_get(name)
            if !(kind === curdef)
                raise TypeError, "#{name} is already defined but it is a #{curdef.class}"
            end
            return curdef
        rescue NameError
            value = yield if !value
            const_set(name, value)
        end
    end
end

class Class
    # Defines an attribute as being enumerable in the class
    # instance and in the whole class inheritance hierarchy
    # 
    # More specifically, it defines
    # a each_#{name}(&iterator) instance method and a 
    # each_#{name}(&iterator) class
    # method which iterates (in order) on 
    # - the class instance #{name} attribute
    # - the singleton class #{name} attribute
    # - the class #{name} attribute
    # - the superclass #{name} attribute
    # - the superclass' superclass #{name} attribute
    # ...
    #
    # It defines also #{name} as being an rw attribute
    def model_enumerator(name, attribute_name = name, enumerate_with = :each)
        class_eval <<-EOF
        def each_#{name}(key = nil, &iterator)
            if key
                #{attribute_name}[key].#{enumerate_with}(&iterator) if #{attribute_name}
            else
                #{attribute_name}.#{enumerate_with}(&iterator) if #{attribute_name}
            end
            singleton_class.each_#{name}(key, &iterator) 
            self.class.each_#{name}(key, &iterator) # Not needed in ruby 1.9
        end

        def self.each_#{name}(key = nil, &iterator)
            if key
                #{attribute_name}[key].#{enumerate_with}(&iterator) if #{attribute_name}
            else
                #{attribute_name}.#{enumerate_with}(&iterator) if #{attribute_name}
            end
            superclass.each_#{name}(key, &iterator) if superclass.respond_to?(:each_#{name})
        end
        attr_accessor :#{attribute_name}
        class << self
            attr_accessor :#{attribute_name}
        end
        EOF
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
    # +nil+ is treated as an empty option hash
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

    def check_arity(object, arity)
        unless object.arity == arity || (object.arity < 0 && object.arity > - arity - 2)
            raise ArgumentError, "#{object} cannot take #{arity} argument(s)"
        end
    end
end

class Thread
    def send_to(object, name, *args, &prc)
        @msg_queue ||= Queue.new
        @msg_queue << [ object, name, args, prc ]
    end
    def process_events
        @msg_queue ||= Queue.new
        while !@msg_queue.empty?
            object, event = *@msg_queue.deq
            event[0]
            @server.send(*@msg_queue.deq)
        end
    end
end

module ObjectStats
    # Allocates no object
    def self.count
        count = 0
        ObjectSpace.each_object { |obj| count += 1}
    end

    # Allocates 1 Hash, which is included in the count
    def self.count_by_class
        by_class = Hash.new(0)
        ObjectSpace.each_object { |obj|
            by_class[obj.class] += 1
            by_class
        }
        by_class
    end

    def self.profile
        enabled = !GC.disable
        before = count_by_class
        yield
        after  = count_by_class
        GC.enable if enabled

        after[Hash] -= 1 # Correction for the call of count_by_class
        profile = before.
            merge(after) { |klass, old, new| new - old }.
            delete_if { |klass, count| count == 0 }
    end

    def self.stats(filter = nil)
        total_count = 0
        output = ""
        count_by_class.each do |klass, obj_count|
            total_count += obj_count
            if !filter || klass.name =~ filter
                output << klass.name << " " << obj_count.to_s << "\n"
            end
        end
        
        (output << "Total object count: #{total_count}")
    end
end

if __FILE__ == $0
    require 'pp'
    raise "Object allocation profile changed" if !ObjectStats.profile { ObjectStats.count }.empty?
    raise "Object allocation profile changed" if { Hash => 1 } != ObjectStats.profile { ObjectStats.count_by_class }
end

