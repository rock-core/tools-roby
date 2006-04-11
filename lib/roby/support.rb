require 'thread'
require 'genom/support'

require 'roby/enumerate'
require 'roby/graph'

module Kernel
    alias :__system__ :system
    def system(*args)
	__system__(*args)
    rescue TypeError
	true
    end
end

# Create a new thread and forward all messages
# to the +forward_to+ object given at initialization.
# The messages are sent in the new thread.
class ThreadServer
    class Quit < RuntimeError; end
    attr_reader :thread

    def initialize(forward_to)
	@forwarded = forward_to
	@queue = Queue.new
	@thread = Thread.new do
	    begin
		loop do
		    message = @queue.pop
		    block = message.pop
		    forward_to.send(*message, &block)
		end
	    rescue ThreadServer::Quit
	    rescue Exception => e
		puts "#{e.message}(#{e.class.name}):in #{e.backtrace.join("\n  ")}"
		raise
	    end
	end
    end
    def method_missing(*args, &block)
	if Thread.current == @thread
	    super
	else
	    args << block
	    @queue.push args
	end
    end
    def quit!
	@thread.raise Quit
	@thread.join
    end
end

class Object
    def attribute(attr_def, &init)
        if Hash === attr_def
            name, defval = attr_def.to_a.flatten
        else
            name = attr_def
        end

        iv_name = "@#{name}"
        define_method("#{name}_attribute_init") do
            newval = defval || (instance_eval(&init) if init)
            self.send("#{name}=", newval)
        end

        class_eval <<-EOF
        def #{name}
            if defined? @#{name}
                @#{name}
            else
                #{name}_attribute_init
            end
        end
        attr_writer :#{name}
        EOF
    end

    def class_attribute(attr_def, &init)
	singleton_class.class_eval do
	    attribute(attr_def, &init)
	end
    end

    def address
	id = object_id
	id = 0xFFFFFFFF - ~id if id < 0
	(id * 2) & 0xFFFFFFFF
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
        rescue NameError => e
	    raise unless e.name == :ClassExtension
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
	if old = constants.find { |cn| cn == name.to_s }
	    return const_get(old)
	else
            const_set(name, (value || yield))
        end
    end

    # Define 'name' to be a read-only enumerable attribute
    def attr_enumerable(name, attr_name = name, enumerator = :each, &init_block)
	class_eval do
	    attribute(attr_name, &init_block)
	end
        class_eval <<-EOF
            def each_#{name}(key = nil, &iterator)
                return unless #{attr_name}
                if key
                    #{attr_name}[key].#{enumerator}(&iterator)
                else
                    #{attr_name}.#{enumerator}(&iterator)
                end
            end
        EOF
    end

    # Emulate block-passing by converting the block into a Proc object
    # and passing it to the given block as last argument
    #
    # For instance
    #   define_method('my_method') do |a, &block|
    #   end
    #
    # Is written as
    #	define_method_with_block('my_method') do |a, block|
    #	end
    def define_method_with_block(name, &mdef)
	
	class_eval <<-EOD
	    def #{name}(*args, &block)
		args << block
		dmwb_#{name}_user_definition(*args) 
	    end
	EOD
	define_method("dmwb_#{name}_user_definition", &mdef)
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
    # It defines also #{name} as a readonly attribute
    def class_inherited_enumerable(name, attribute_name = name, options = Hash.new, &init)
        # Set up the attribute accessor
	class_attribute(attribute_name, &init)
	singleton_class.class_eval { private "#{attribute_name}=" }

	options[:enum_with] ||= :each

        if options[:map]
            singleton_class.class_eval <<-EOF
            def each_#{name}(key = nil, uniq = true, &iterator)
		if key
		    if #{attribute_name}.has_key?(key)
			iterator[#{attribute_name}[key]] 
			return self if uniq
		    end
		elsif uniq
		    enum_uniq(:each_#{name}, nil, false) { |k, v| k }.
			each(&iterator)
		    return self
		else
                    #{attribute_name}.#{options[:enum_with]}(&iterator)
		end
		superclass_call(:each_#{name}, key, uniq, &iterator)
                self
            end
            def has_#{name}?(key)
                return true if #{attribute_name}[key]
		superclass_call(:has_#{name}, key)
            end
            EOF
        else
            singleton_class.class_eval <<-EOF
            def each_#{name}(&iterator)
                #{attribute_name}.#{options[:enum_with]}(&iterator) if #{attribute_name}
		superclass_call(:each_#{name}, &iterator)
                self
            end
            EOF
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
	loop do
            object, name, args, block = *@msg_queue.deq(true)
            object.send(name, *args, &block)
        end
    rescue ThreadError
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

class Logger
    module Hierarchy
        attr_writer :logger
        def logger(parent_module = Module.nesting[1])
            return @logger if defined?(@logger) && @logger
            if kind_of?(Module)
                modname = self.name
                modname = modname.split("::")[0..-2].join("::")
                const_get(modname).logger
            else
                self.class.logger
            end
        end
    end
    module Forward
        [ :debug, :info, :warn, :error, :fatal, :unknown ].each do |level|
            class_eval <<-EOF
                def #{level}(*args, &proc); logger.#{level}(*args, &proc) end
            EOF
        end
  	def loglevel=(value); logger.level = value end
	def loglevel; logger.level end
    end
end

require 'logger'
module Roby
    @logger = Logger.new(STDERR)
    @logger.level = Logger::DEBUG
    @logger.progname = "Roby"
    @logger.formatter = lambda { |severity, time, progname, msg| "#{progname}: #{msg}\n" }

    extend Logger::Hierarchy
    extend Logger::Forward
end

if __FILE__ == $0
    require 'pp'
    raise "Object allocation profile changed" if !ObjectStats.profile { ObjectStats.count }.empty?
    raise "Object allocation profile changed" if { Hash => 1 } != ObjectStats.profile { ObjectStats.count_by_class }
end

