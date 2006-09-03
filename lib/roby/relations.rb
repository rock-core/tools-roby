require 'roby/support'

module Roby
    class NoRelationError < RuntimeError; end

    # Base support for relations. It is mixed-in objects that are
    # part of relation networks (like Task and EventGenerator)
    # It is used by the DirectedRelation module, which is used
    # to define the relation modules (like TaskSupport::Hierarchy)
    module DirectedRelationSupport
	# An array of relation types this object is part of
	attribute(:relations) { Set.new }

	def each_object_aux(parent, child)
	    relations.each do |type|
		type.each_parent_object(self) { |o| yield(o) } if parent
		type.each_child_object(self)  { |o| yield(o) } if child
	    end
	end
	private :each_object_aux

	def each_parent_object
	    enum = (@__each_parent_enum__ ||= enum_for(:each_object_aux, true, false))
	    enum.each_uniq { |o| yield(o) }
	end
	def each_child_object
	    enum = (@__each_child_enum__ ||= enum_for(:each_object_aux, false, true))
	    enum.each_uniq { |o| yield(o) }
	end
	# Cannot have the same object as parent and child
	def each_related_object
	    each_parent_object { |o| yield(o) }
	    each_child_object { |o| yield(o) }
	end

	# true if +obj+ is a child of +self+ for the relation +type+
	# If +type+ is nil, it considers all relations
	def child_object?(obj, type = nil)
	    check_is_relation(type)
	    apply_selection(type, relations).
		find { |type| type.child_object?(self, obj) }
	end

	# true if +obj+ is a parent of +self+ for the relation +type.
	# If +type+ is nil, it considers all relations
	def parent_object?(obj, type = nil)
	    check_is_relation(type)
	    apply_selection(type, relations).
		find { |type| type.parent_object?(self, obj) }
	end

	# true if +obj+ is related to +self+ for the relation +type+ 
	# If +type+ is nil, it considers all relations
	def related_object?(obj, type = nil); child_object?(obj, type) || parent_object?(obj, type) end


	# Enumerate all relations this object is part of.
	# If directed is false, then we enumerate both parents
	# and children.
	def each_relation(directed = false) # :yield: type, parent, child
	    relations.inject(null_enum) { |enum, type| enum + type.enum_for(:each_relation, self, directed) }.
		each_uniq { |o| yield(o) }
	end

	# Add a new relation
	def add_child_object(to, type, info = nil)
	    check_is_relation(type)
	    relations << type
	    to.relations << type
	    type.add_child(self, to, info)

	    added_child_object(to, type, info)
	end
	# Hook called after a new child has been added
	def added_child_object(to, type, info)
	    super if defined? super
	end

	# Remove relations where self is a parent
	def remove_child_object(to, type = nil)
	    check_is_relation(type)
	    apply_selection(type, relations) do |type|
		type.remove_child(self, to)
		removed_child_object(to, type)
	    end
	end
	def remove_children(type = nil)
	    apply_selection(type, relations) do |type|
		type.each_child_object(self) do |to|
		    remove_child_object(to, type)
		end
	    end
	end
	# Hook called after a child has been removed
	def removed_child_object(to, type)
	    super if defined? super
	end

	# Remove relations where self is a child
	def remove_parent_object(to, type = nil)
	    check_is_relation(type)
	    apply_selection(type, relations) do |type|
		type.remove_parent(self, to)
		removed_parent_object(to, type)
	    end
	end
	def remove_parents(type = nil)
	    check_is_relation(type)
	    apply_selection(type, relations) do |type|
		type.each_parent_object(self) do |to|
		    remove_parent_object(type, to)
		end
	    end
	end
	# Hook called after a parent has been removed
	def removed_parent_object(to, type)
	    super if defined? super
	end

	# Remove all relations that point to or come from +to+
	# If +to+ is nil, it removes all relations related to +self+
	def remove_relations(to = nil, type = nil)
	    check_is_relation(type)
	    remove_child_object(to, type)
	    remove_parent_object(to, type)
	end

	def check_is_relation(type)
	    if type && !type.respond_to?(:relation_type)
		raise ArgumentError, "#{type} is not a relation type"
	    end
	end

	def apply_selection(object, enumerator)
	    if block_given?
		if object; yield(object)
		else enumerator.each { |o| yield(o) }
		end
	    else
		if object; [object]
		else; enumerator
		end
	    end
	end
	private :apply_selection
	
	## The following attributes are used by SimpleDirectedRelation
	# A type -> parent map
	attribute(:parents) do Hash.new { |h, k| h[k] = Set.new } end
	# A type -> children map
	attribute(:children) do Hash.new { |h, k| h[k] = Hash.new } end
    end

    module DirectedRelation
	module ClassExtension
	    def relation_type; self end

	    attribute(:subsets) { Set.new }
	    # Returns true if +relation+ is included in this relation (i.e. it is either
	    # the same relation or one of its subsets)
	    def include?(relation)
		relation_type == relation || subsets.each { |subrel| subrel.include?(relation) }
	    end

	    def add_child(from, to, info)
		to.parents[relation_type] << from
		from.children[relation_type][to] = info
	    end
	    def remove_child(from, to)
		to.parents[relation_type].delete(from)
		from.children[relation_type].delete(to)
	    end

	    # true if +obj+ is a child of +of+ for this relation
	    def child_object?(of, obj)
		of.children[relation_type].has_key?(obj) ||
		    subsets.find { |mod| mod.child_object?(of, obj) }
	    end

	    # true if +obj+ is a parent object of +of+ for this relation 
	    def parent_object?(of, obj); child_object?(obj, of) end

	    def each_relation(of, directed)
		of.children[relation_type].each do |to, info|
		    yield(relation_type, of, to, info)
		end
		if !directed
		    of.parents[relation_type].each do |parent|
			yield(relation_type, parent, of, parent.children[relation_type][of])
		    end
		end
	    end

	    def each_parent_object(of) # :yield: parent_object
		of.parents[relation_type].each { |o| yield(o) }
		subsets.each { |mod| mod.each_parent_object(of) { |o| yield(o) } }
	    end
	    def each_child_object(of)  # :yield: child_object
		of.children[relation_type].each_key { |o| yield(o) }
		subsets.each { |mod| mod.each_child_object(of) { |o| yield(o) } }
	    end
	    def each_related_object(of, &iterator)
		each_parent_object(of, &iterator)
		each_child_object(of, &iterator)
	    end
	    
	    # Defines enumerators in the node objects for this relationship. 
	    # It defines each_#{parent} and each_#{child}. Set either to nil
	    # to disable the definition
	    def parent_enumerator(name); @parent_enumerator_name = name end
	    def module_name(new_name = nil)
		if new_name
		    @module_name = new_name 
		else
		    @module_name
		end
	    end

	    attr_reader :parent_enumerator_name

	    # Declare that this relation is a superset of the following relations.
	    # For practical purposes, this means that each_parent_object and each_child_object will also
	    # enumerate the relations defined by the subset relations
	    def superset_of(relation)
		subsets << relation
	    end
	end
    end

    def self.RelationSpace(klass, &block)
	relation_space = Module.new
	relation_space.singleton_class.class_eval do
	    define_method(:new_relation_type) do |relation_name, block|
		mod = Module.new
		
		mod.include DirectedRelation
		mod.class_eval(&block) if block
		mod.module_name(mod.module_name || relation_name.to_s.camelize.pluralize)

		if mod.parent_enumerator_name
		    mod.class_eval <<-EOD
		    def each_#{mod.parent_enumerator_name}(&iterator)
			@@__r_#{relation_name}__.each_parent_object(self, &iterator)
		    end
		    EOD
		end
		    
		mod.singleton_class.class_eval { define_method("__r_#{relation_name}__") { mod } }
		mod.class_eval <<-EOD
		@@__r_#{relation_name}__ = __r_#{relation_name}__
		def each_#{relation_name}(&iterator)
		    @@__r_#{relation_name}__.each_child_object(self, &iterator)
		end
		def add_#{relation_name}(to, info = nil)
		    add_child_object(to, @@__r_#{relation_name}__, info)
		    self
		end
		def remove_#{relation_name}(to)
		    remove_child_object(to, @@__r_#{relation_name}__)
		    self
		end
		EOD

		relation_space.const_set(mod.module_name, mod)
		klass.include mod

		mod
	    end
	end
	relation_space.singleton_class.class_eval "def relation(mod, &block); new_relation_type(mod, block) end"
	relation_space.class_eval(&block) if block_given?
	relation_space
    end

    class Task
	include DirectedRelationSupport
    end
    class EventGenerator
	include DirectedRelationSupport
    end
    
    TaskStructure   = RelationSpace(Task)
    EventStructure  = RelationSpace(EventGenerator)
end

