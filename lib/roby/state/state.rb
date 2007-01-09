module Roby
    # ExtendedStruct objects are OpenStructs where
    # attributes have a default class. They are used to 
    # build hierarchical data structure on-the-fly
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
    # You'll have to test with respond_to?
    #	if (root.respond_to?(:child)
    #	    <do something>
    #	end
    #
    class ExtendedStruct
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
            @attach_as = [attach_to, attach_name] if attach_to
	    @children_class = children_class

            @stable = false
            @members = Hash.new
	    @pending = Hash.new
	    @filters = Hash.new
	    @aliases = Hash.new
        end

	def self._load(io)
	    members, aliases = Marshal.load(io)

	    result = ExtendedStruct.new
	    result.instance_variable_set("@members", members)
	    result.instance_variable_set("@aliases", aliases)
	    result
	end

	def _dump(lvl = -1)
	    Marshal.dump([@members, @aliases])
	end

	attr_reader :children_class

	attr_reader :attach_as
        def attach # :nodoc:
	    if @attach_as
		attach_to, attach_name = @attach_as
		@attach_as = nil
		attach_to.send("#{attach_name}=", self)
	    end
        end
	def detach
	    @attach_as = nil
	end
	protected :detach, :attach_as
        
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

	def delete(name)
	    raise TypeError, "#{self} is stable" if stable?
	    @members.delete(self)
	    @pending.delete(self)
	end

	# Define a filter for the +name+ attribute on self. The given block
	# is called when the attribute is written, and should return true if
	# the new value if valid or false otherwise
	def filter(name, &block)
	    @filters["#{name}="] = block
	end
	
	# If self is stable, it cannot be updated. That is, calling a setter method
	# raises NoMethodError
        def stable?; @stable end

	# Sets the stable attribute of +self+ to +is_stable+. If +recursive+ is true,
	# set it on the child struct as well. 
        def stable!(recursive = false, is_stable = true)
            @stable = is_stable
            if recursive
                @members.each { |name, object| object.stable!(recursive, is_stable) if object.respond_to?(:stable!) }
            end
        end

        def respond_to?(name) # :nodoc:
            return true  if super

            name = name.to_s
	    return false if name =~ /marshal_/
	    return false if name =~ /^to_/

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

        def method_missing(name, *args, &update) # :nodoc:
            name = name.to_s

	    raise NoMethodError if name =~ /^marshal_/
	    super if name =~ /^to_/
            if name =~ /(.+)=$/
		# Setter
		attribute_name = $1

		attach

		value = *args
                if stable?
                    raise NoMethodError, "#{self} is stable"
		elsif @filters[name] && !@filters[name].call(value)
		    raise ArgumentError, "value #{value} is not valid for #{name}"
		else
		    @aliases.delete(attribute_name)
		    pending = @pending.delete(attribute_name)

		    if pending && pending != value
			pending.detach
		    end
                    @members[name[0..-2]] = value
                end

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
		super
            end
        end

	def alias(from, to)
	    @aliases[to.to_s] = from.to_s
	end
    end

    class StateSpace < ExtendedStruct
	def initialize(children_class = StateSpace, attach_to = nil, attach_name = nil)
	    super
	end
    end

    State = ExtendedStruct.new
end

