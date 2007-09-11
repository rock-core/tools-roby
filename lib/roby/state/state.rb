module Roby
    # ExtendedStruct objects are OpenStructs where attributes have a default
    # class. They are used to build hierarchical data structure on-the-fly
    #
    # For instance
    #	root = ExtendedStruct.new
    #	root.child.value = 42
    #
    # However, you *cannot* check if a value is defined or not with
    #	if (root.child)
    #	    <do something>
    #	end
    #
    # You'll have to test with respond_to? or #{name}?. The second one will
    # return true only if the attribute is defined <b>and</b> it is not false
    #	if (root.respond_to?(:child)
    #	    <do something>
    #	end
    #
    # == Handling of methods defined on parents
    #
    # Methods defined in Object or Kernel are automatically overriden if needed.
    # For instance, if you're managing a (x, y, z) position using ExtendedStruct, 
    # you will want YAML#y to *not* get in the way. The exceptions are the methods
    # listed in NOT_OVERRIDABLE
    #
    class ExtendedStruct
	include DRbUndumped

	# +attach_to+ and +attach_name+
	# are used so that
	#   root = ExtendedStruct.new
	#   root.bla
	# does *not* add a +bla+ attribute to root, while the following constructs
	#   root.bla.test = 20
	#   bla = root.bla
	#   bla.test = 20
	# does
	#
	# Note, however that
	#   bla = root.bla
	#   root.bla = 10
	#   bla.test = 20
	#   
	# will *not* make root.bla be the +bla+ object. And that
	# 
	#   bla = root.bla
	#   root.stable!
	#   bla.test = 20
	#
	# will not fail
	def initialize(children_class = ExtendedStruct, attach_to = nil, attach_name = nil) # :nodoc
	    clear
            @attach_as = [attach_to, attach_name.to_s] if attach_to
	    @children_class = children_class
            @observers       = Hash.new { |h, k| h[k] = [] }
        end

	def clear
	    @attach_as	     = nil
            @stable          = false
            @members         = Hash.new
            @pending         = Hash.new
            @filters         = Hash.new
            @aliases         = Hash.new
	end

	def self._load(io)
	    marshalled_members, aliases = Marshal.load(io)
	    members = marshalled_members.inject({}) do |h, (n, mv)|
		begin
		    h[n] = Marshal.load(mv)
		rescue Exception
		    Roby::Distributed.warn "cannot load #{n} #{mv}: #{$!.message}"
		end

		h
	    end

	    result = ExtendedStruct.new
	    result.instance_variable_set("@members", members)
	    result.instance_variable_set("@aliases", aliases)
	    result

	rescue Exception
	    Roby::Distributed.warn "cannot load #{members} #{io}: #{$!.message}"
	    raise
	end

	def _dump(lvl = -1)
	    marshalled_members = @members.map do |name, value|
		[name, Marshal.dump(value)] rescue nil
	    end
	    marshalled_members.compact!
	    Marshal.dump([marshalled_members, @aliases])
	end

	attr_reader :children_class

	attr_reader :attach_as, :__parent_struct, :__parent_name
        def attach # :nodoc:
	    if @attach_as
		@__parent_struct, @__parent_name = @attach_as
		@attach_as = nil
		__parent_struct.attach_child(__parent_name, self)
	    end
        end
	def detach
	    @attach_as = nil
	end
	def attach_child(name, obj)
	    @members[name.to_s] = obj
	end
	protected :detach, :attach_as

	# Call +block+ with the new value if +name+ changes
	def on(name = nil, &block)
	    name = name.to_s if name
	    @observers[name] << block
	end

	def to_hash; @members.to_sym_keys end
	def each_member(&block)
	    @members.each(&block)
	end
        
	# Update a set of values on this struct
	# If a hash is given, it is an name => value hash of attribute
	# values. A given block is yield with self, so that the construct
	#
	#   my.extendable.struct.very.deep.update do |deep|
	#     <update deep>
	#   end
	#
	# can be used 
        def update(hash = nil)
	    attach
            hash.each { |k, v| send("#{k}=", v) } if hash
            yield(self) if block_given?
            self
        end

	def delete(name = nil)
	    raise TypeError, "#{self} is stable" if stable?
	    if name
		name = name.to_s
		if child = @members.delete(name)
		    child.instance_variable_set(:@__parent_struct, nil)
		    child.instance_variable_set(:@__parent_name, nil)
		elsif child = @pending.delete(name)
		    child.instance_variable_set(:@attach_as, nil)
		elsif child = @aliases.delete(name)
		    # nothing to do here
		else
		    raise ArgumentError, "no such child #{name}"
		end

		# and remove aliases that point to +name+
		@aliases.delete_if { |_, pointed_to| pointed_to == name }
	    else
		if __parent_struct
		    __parent_struct.delete(__parent_name)
		elsif @attach_as
		    @attach_as.first.delete(@attach_as.last)
		else
		    raise ArgumentError, "#{self} is attached to nothing"
		end
	    end
	end

	# Define a filter for the +name+ attribute on self. The given block
	# is called when the attribute is written, and should return true if
	# the new value if valid or false otherwise
	def filter(name, &block)
	    @filters[name.to_s] = block
	end
	
	# If self is stable, it cannot be updated. That is, calling a setter method
	# raises NoMethodError
        def stable?; @stable end

	# Sets the stable attribute of +self+ to +is_stable+. If +recursive+ is true,
	# set it on the child struct as well. 
	#
        def stable!(recursive = false, is_stable = true)
            @stable = is_stable
            if recursive
                @members.each { |name, object| object.stable!(recursive, is_stable) if object.respond_to?(:stable!) }
            end
        end

	def updated(name, value)
	    if @observers.has_key?(name)
		@observers[name].each { |b| b.call(value) }
	    end
	    @observers[nil].each { |b| b.call(value) }

	    if __parent_struct
		__parent_struct.updated(__parent_name, self)
	    end
	end

	# Returns true if this object has no member
	def empty?; @members.empty? end

        def respond_to?(name) # :nodoc:
            return true  if super

            name = name.to_s
	    return false if name =~ FORBIDDEN_NAMES_RX

            if name =~ /=$/
		!@stable
            else
                if @members.has_key?(name)
		    true
		else
		    (alias_to = @aliases[name]) && respond_to?(alias_to)
		end
            end
        end

	def get(name, default_value)
	    if respond_to?(name)
		send(name.to_sym)
	    else
		default_value
	    end
	end

	FORBIDDEN_NAMES=%w{marshal each enum to}.map { |str| "^#{str}_" }
	FORBIDDEN_NAMES_RX = /(?:#{FORBIDDEN_NAMES.join("|")})/

	NOT_OVERRIDABLE = %w{class} + instance_methods(false)
	NOT_OVERRIDABLE_RX = /(?:#{NOT_OVERRIDABLE.join("|")})/

        def method_missing(name, *args, &update) # :nodoc:
	    name = name.to_s

	    super(name.to_sym, *args, &update) if name =~ FORBIDDEN_NAMES_RX
            if name =~ /(.+)=$/
		# Setter
		name = $1

		value = *args
                if stable?
                    raise NoMethodError, "#{self} is stable"
		elsif @filters.has_key?(name) && !@filters[name].call(value)
		    raise ArgumentError, "value #{value} is not valid for #{name}"
		elsif !@members.has_key?(name) && !@aliases.has_key?(name) && respond_to?(name)
		    if NOT_OVERRIDABLE_RX =~ name
			raise ArgumentError, "#{name} is already defined an cannot be overriden"
		    end

		    # Override it
		    singleton_class.class_eval { private name }
		end

		attach


		@aliases.delete(name)
		pending = @pending.delete(name)

		if pending && pending != value
		    pending.detach
		end

		@members[name] = value
		updated(name, value)
                return value

	    elsif name =~ /(.+)\?$/
		# Test
		name = $1
		respond_to?(name) && send(name)

            elsif args.empty? # getter
		attach

		if @members.has_key?(name)
		    member = @members[name]
		else
		    if alias_to = @aliases[name]
			return send(alias_to)
		    elsif stable?
			raise NoMethodError, "no such attribute #{name} (#{self} is stable)"
		    else
			member = children_class.new(children_class, self, name)
			@pending[name] = member
		    end
		end

                if update
                    member.update(&update)
		else
                    member
                end

	    else
		super(name.to_sym, *args, &update)
            end
        end

	def alias(from, to)
	    @aliases[to.to_s] = from.to_s
	end
    end

    class StateSpace < ExtendedStruct
	def initialize
            @exported_fields = Set.new
	    super
	end

	def _dump(lvl = -1)
	    marshalled_members = @exported_fields.map do |name|
		value = @members[name]
		[name, Marshal.dump(value)] rescue nil
	    end
	    marshalled_members.compact!
	    Marshal.dump([marshalled_members, @aliases])
	end

	def deep_copy
	    exported_fields, @exported_fields = @exported_fields, Set.new
	    Marshal.load(Marshal.dump(self))
	ensure
	    @exported_fields = exported_fiels
	end

	def testing?; Roby.app.testing? end
	def simulation?; Roby.app.simulation? end
	def export(*names)
	    @exported_fields.merge names.map { |n| n.to_s }.to_set
	end
    end

    State = StateSpace.new
end

