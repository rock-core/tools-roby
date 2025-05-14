# frozen_string_literal: true

module Roby
    # This module defines functionality that can be mixed-in other objects to
    # have an 'automatically extensible struct' behaviour, i.e.
    #
    # Roby::OpenStruct objects are OpenStructs where attributes have a default
    # class. They are used to build hierarchical data structure on-the-fly.
    # Additionally, they may have a model which constrains what can be created
    # on them
    #
    # For instance
    #
    # @example create an openstruct and assign a value in the hierarchy
    #   root = Roby::OpenStruct.new
    #   root.child.value = 42
    #
    # However, you *cannot* check if a value is defined or not with
    #
    #   if (root.child)
    #       <do something>
    #   end
    #
    # You'll have to test with respond_to? or field_name?. The second one will
    # return true only if the attribute is defined <b>and</b> it is not false
    #
    # @example test for the presence of a value in the hierarchy
    #   if root.respond_to?(:child)
    #       <do something if child has been set>
    #   end
    #   if root.child?
    #       <do something if child has been set and is non-nil>
    #   end
    #
    # == Handling of methods defined on parents
    #
    # Methods defined in Object or Kernel are automatically overriden if needed.
    # For instance, if you're managing a (x, y, z) position using OpenStruct,
    # you will want YAML#y to *not* get in the way. The exceptions are the methods
    # listed in NOT_OVERRIDABLE
    #
    class OpenStruct
        attr_reader :model, :attach_as, :__parent_struct, :__parent_name

        # +attach_to+ and +attach_name+
        # are used so that
        #   root = OpenStruct.new
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
        def initialize(model = nil, attach_to = nil, attach_name = nil)
            clear

            @model = model
            @observers = Hash.new { |h, k| h[k] = [] }
            @filters = {}

            if attach_to
                link_to(attach_to, attach_name)
            end

            if model
                attach_model
                attach
            end
        end

        def clear
            @attach_as       = nil
            @stable          = false
            @members         = {}
            @pending         = {}
            @aliases         = {}
        end

        def clear_model
            @model = nil
        end

        def pretty_print(pp)
            pp.seplist(@members) do |child|
                child_name, child_obj = *child
                if child_obj.kind_of?(OpenStruct)
                    pp.text "#{child_name} >"
                else
                    pp.text child_name.to_s
                end
                pp.breakable
                child_obj.pretty_print(pp)
            end
        end

        def self._load(io)
            marshalled_members, aliases = Marshal.load(io)

            result = new
            marshalled_members.each do |name, marshalled_field|
                begin
                    value = Marshal.load(marshalled_field)
                    if value.kind_of?(OpenStruct)
                        value.attach_to(result, name)
                    else
                        result.set(name, value)
                    end
                rescue Exception
                    Roby::DRoby.warn "cannot load #{name} #{marshalled_field}: #{$!.message}"
                end
            end

            result.instance_variable_set("@aliases", aliases)
            result
        rescue Exception
            Roby::DRoby.warn "cannot load #{marshalled_members} #{io}: #{$!.message}"
            raise
        end

        def _dump(lvl = -1)
            marshalled_members = @members.map do |name, value|
                [name, Marshal.dump(value)] rescue nil
            end
            marshalled_members.compact!
            Marshal.dump([marshalled_members, @aliases])
        end

        # Create a model structure and associate it with this openstruct
        def new_model
            unless @model
                @model = create_model
                attach_model
            end
            @model
        end

        def create_model
            OpenStructModel.new
        end

        # Do the necessary initialization after having added a model to this
        # task
        def attach_model
            model.each_member do |name, field|
                case field
                when OpenStructModel
                    @members[name] ||= create_subfield(name)
                end
            end

            # Trigger updating the structure whenever the state model is
            # changed
            model.on_change(nil, false) do |name, value|
                if value.kind_of?(OpenStructModel)
                    @members[name] ||= create_subfield(name)
                end
            end
        end

        def link_to(parent, name)
            @attach_as = [parent, name]
        end

        def attach_to(parent, name)
            link_to(parent, name)
            attach
        end

        class Stable < RuntimeError; end

        # When a field is dynamically created by #method_missing, it is created
        # in a pending state, in which it is not yet attached to its parent
        # structure
        #
        # This method does the attachment. It calls #attach_child on the parent
        # to notify it
        def attach
            return unless @attach_as

            parent_struct, parent_name = @attach_as
            if parent_struct.stable? && !parent_struct.member?(parent_name)
                raise Stable,
                      "cannot attach #{self} on #{parent_struct}, the parent is stable " \
                      "and attaching would create a new field named #{parent_name}"
            end

            @__parent_struct, @__parent_name = @attach_as
            @attach_as = nil
            __parent_struct.attach_child(__parent_name, self)
            @model&.attach
        end

        # When a field is dynamically created by #method_missing, it is created
        # in a pending state, in which it is not yet attached to its parent
        # structure
        #
        # This method makes sure that the field will never be attached to the
        # parent. It has no effect once #attach has been called
        def detach
            @attach_as = nil
        end

        # Called by a child when #attach is called
        def attach_child(name, obj)
            @members[name.to_s] = obj
            updated(name, obj)
        end
        protected :detach, :attach_as

        def __root?
            !__parent
        end

        def __parent
            @__parent_struct ||
                (@attach_as[0] if @attach_as)
        end

        def __root
            if p = __parent
                p.__root
            else
                self
            end
        end

        # If true, this field is attached to a parent structure
        def attached?
            !!@__parent_struct
        end

        # Internal data structure used to register the observers defined with
        # #on_change
        class Observer
            def recursive?
                !!@recursive
            end

            def initialize(recursive, block)
                @recursive, @block = recursive, block
            end

            def call(name, value)
                @block.call(name, value)
            end
        end

        # Call +block+ with the new value if +name+ changes
        #
        # If name is not given, it will be called for any change
        def on_change(name = nil, recursive = false, &block)
            attach
            name = name.to_s if name
            @observers[name] << Observer.new(recursive, block)
            self
        end

        # Converts this OpenStruct into a corresponding hash, where all
        # keys are symbols. If +recursive+ is true, any member which responds
        # to #to_hash will be converted as well
        def to_hash(recursive = true)
            result = {}
            @members.each do |k, v|
                result[k.to_sym] = if recursive && v.respond_to?(:to_hash)
                                       v.to_hash
                                   else
                                       v
                                   end
            end
            result
        end

        # Iterates on all defined members of this object
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
            hash&.each { |k, v| send("#{k}=", v) }
            yield(self) if block_given?
            self
        end

        def delete(name = nil)
            raise TypeError, "cannot delete #{name}, #{self} is stable" if stable?

            if name
                name = name.to_s
                child = @members.delete(name) || @pending.delete(name)
                child.detached! if child.respond_to?(:detached!)

                # We don't detach aliases
                if !child && !@aliases.delete(name)
                    raise ArgumentError, "no such child #{name}"
                end

                # and remove aliases that point to +name+
                @aliases.delete_if { |_, pointed_to| pointed_to == name }
            elsif __parent_struct
                __parent_struct.delete(__parent_name)
            elsif @attach_as
                @attach_as.first.delete(@attach_as.last)
            else
                raise ArgumentError, "#{self} is attached to nothing"
            end
        end

        def detached!
            @__parent_struct, @__parent_name, @attach_as = nil
        end

        # Define a filter for the +name+ attribute on self. The given block is
        # called when the attribute is written with both the attribute name and
        # value. It should return the value that should actually be written, and
        # raise an exception if the new value is invalid.
        def filter(name, &block)
            @filters[name.to_s] = block
        end

        # Define a filter for the +name+ attribute on self. The given block is
        # called when the attribute is written with both the attribute name and
        # value. It should return the value that should actually be written, and
        # raise an exception if the new value is invalid.
        def global_filter(&block)
            @filters[nil] = block
        end

        # If self is stable, its structure cannot be changed
        #
        # Any modification that would create new fields will raise a {Stable} exception
        def stable?
            @stable
        end

        def freeze
            freeze
            each_member do |name, field|
                field.freeze
            end
        end

        # Sets the stable attribute of +self+ to +is_stable+. If +recursive+ is true,
        # set it on the child struct as well.
        #
        def stable!(recursive = false, is_stable = true)
            @stable = is_stable
            return unless recursive

            @members.each do |(_, object)|
                object.stable!(recursive, is_stable) if object.respond_to?(:stable!)
            end
        end

        def updated(name, value, recursive = false)
            if @observers.has_key?(name)
                @observers[name].each do |ob|
                    if ob.recursive? || !recursive
                        ob.call(name, value)
                    end
                end
            end

            @observers[nil].each do |ob|
                if ob.recursive? || !recursive
                    ob.call(name, value)
                end
            end

            __parent_struct&.updated(__parent_name, self, true)
        end

        # Returns true if this object has no member
        def empty?
            @members.empty?
        end

        # has_method? will be used to know if a given method is already defined
        # on the OpenStruct object, without taking into account the members
        # and aliases.
        def has_method?(name)
            return false unless respond_to?(name, true)

            name = name.to_s
            if name.end_with?("?") || name.end_with?("=")
                name = name[0..-2]
            end

            !member?(name) && !alias?(name)
        end

        def respond_to_missing?(name, include_private = false) # :nodoc:
            return true if super

            name = name.to_s
            return false if name =~ FORBIDDEN_NAMES_RX

            if name.end_with?("=") || name.end_with?("?")
                name = name[0..-2]
                return true if member?(name) || alias?(name)
                return false if respond_to?(name, include_private)

                !@stable
            elsif member?(name) || alias?(name)
                true
            else
                (alias_to = @aliases[name]) && respond_to?(alias_to)
            end
        end

        # Returns the value of the given field
        #
        # Unlike #method_missing, it will return nil if the field is not set
        def get(name)
            __get(name, false)
        end

        # Returns the path to root, i.e. the list of field names from the root
        # of the extended struct tree
        def path
            result = []
            obj = self
            while obj
                result.unshift(obj.__parent_name)
                obj = obj.__parent_struct
            end
            result.shift # we alwas add a nil for one-after-the-root
            result
        end

        def __get(name, create_substruct = true, &update)
            name = name.to_s

            if model
                # We never automatically create levels as the model should tell us
                # what we want
                create_substruct = false
            end

            if @members.has_key?(name)
                member = @members[name]
            elsif alias_to = @aliases[name]
                return send(alias_to)
            elsif stable?
                raise Stable, "no such attribute #{name} (#{self} is stable)"
            elsif create_substruct
                attach
                member = @pending[name] = create_subfield(name)
            else
                return
            end

            if update
                member.update(&update)
            else
                member
            end
        end

        # Called by #method_missing to create a subfield when needed.
        #
        # The default is to create a subfield of the same class than +self+
        def create_subfield(name)
            model = self.model&.get(name)
            self.class.new(model, self, name)
        end

        def set(name, *args)
            name = name.to_s
            name = @aliases[name] || name

            if model && !model.get(name).kind_of?(OpenStructModel::Variable)
                raise ArgumentError, "#{name} is not a state variable on #{self}"
            end

            value = args.first

            attach_model, attach_name = @attach_as
            if attach_model&.stable? && !attach_model.member?(attach_name)
                raise Stable,
                      "cannot set #{name}, its parent #{parent_state} is stable and " \
                      "setting it would create a new field #{attach_name} on the parent"
            elsif stable? && !member?(name)
                raise Stable,
                      "cannot set #{name} on #{self}, it is stable and currently has " \
                      "no such field"
            elsif @filters.has_key?(name)
                value = @filters[name].call(value)
            elsif @filters.has_key?(nil)
                value = @filters[nil].call(name, value)
            end

            if has_method?(name)
                if NOT_OVERRIDABLE_RX =~ name
                    raise ArgumentError,
                          "#{name} is already defined an cannot be overriden"
                end

                # Override it
                singleton_class.class_eval do
                    define_method(name) do
                        method_missing(name)
                    end
                end
            end

            attach

            @aliases.delete(name)
            pending = @pending.delete(name)

            if pending && pending != value
                pending.detach
            end

            @members[name] = value
            updated(name, value)
            value
        end

        def method_missing(name, *args, &update) # :nodoc:
            if name !~ /^\w+(?:\?|=|!)?$/
                if name.end_with?("?")
                    return false
                else
                    super
                end
            end

            name = name.to_s

            if name =~ FORBIDDEN_NAMES_RX
                super(name.to_sym, *args, &update)
            end

            if name.end_with?("=")
                key = name[0..-2]
                set(key, *args)

            elsif name.end_with?("?")
                key = name[0..-2]
                name = @aliases[key] || key
                respond_to?(name) && get(name) && send(name)

            elsif args.empty? # getter
                attach unless member?(name)
                __get(name, &update)

            else
                super(name.to_sym, *args, &update)
            end
        end

        def alias(from, to)
            @aliases[to.to_s] = from.to_s
        end

        FORBIDDEN_NAMES = %w{marshal each enum to}.map { |str| "^#{str}_" }
        FORBIDDEN_NAMES_RX = /(?:#{FORBIDDEN_NAMES.join('|')})/.freeze

        NOT_OVERRIDABLE = %w{class} + instance_methods(false)
        NOT_OVERRIDABLE_RX = /(?:#{NOT_OVERRIDABLE.join('|')})/.freeze

        def member?(name)
            @members.key?(name.to_s)
        end

        def alias?(name)
            @aliases.key?(name.to_s)
        end

        def __merge(other)
            @members.merge(other) do |k, v1, v2|
                if v1.kind_of?(OpenStruct) && v2.kind_of?(OpenStruct)
                    if v1.class != v2.class
                        raise ArgumentError, "#{k} is a #{v1.class} in self and #{v2.class} in other, I don't know what to do"
                    end

                    v1.__merge(v2)
                else
                    v2
                end
            end
        end
    end
end
