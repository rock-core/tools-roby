require 'roby/support'

module Roby
    class NoRelationError < RuntimeError; end

    # Base support for relations. It is mixed-in objects that are
    # part of relation networks (like Task and EventGenerator)
    # It is used by the DirectedRelation module, which is used
    # to define the relation modules (like TaskSupport::Hierarchy)
    module DirectedRelationSupport
	# An array of relation types this object is part of
	attribute(:relations) { Array.new }

	def each_parent_object(type = nil, &iterator)
	    enum_for(:apply_selection, type, relations, :each).
		inject(NullEnumerator.new) { |enum, type| enum + type.enum_for(:each_parent_object, self) }.
		enum_uniq { |obj| obj }.
		each(&iterator)
	end
	def each_child_object(type = nil)
	    enum_for(:apply_selection, type, relations, :each).
		inject(NullEnumerator.new) { |enum, type| enum + type.enum_for(:each_child_object, self) }.
		enum_uniq { |obj| obj }.
		each { |child, _| yield(child) }
	end
	def each_related_object(type = nil, &iterator)
	    (enum_for(:each_parent_object, type) + enum_for(:each_child_object, type)).
		enum_uniq { |obj| obj }.
		each(&iterator)
	end

	def child_object?(obj, type = nil)
	    enum_for(:apply_selection, type, relations, :each).
		find { |type| type.child_object?(self, obj) }
	end
	def parent_object?(obj, type = nil)
	    enum_for(:apply_selection, type, relations, :each).
		find { |type| type.parent_object?(self, obj) }
	end
	def related_object?(obj, type = nil); child_object?(obj, type) || parent_object?(obj, type) end


	# Enumerate all relations this object is part of.
	# If directed is false, then we enumerate both parents
	# and children.
	def each_relation(directed = false, &iterator) # :yield: type, parent, child
	    relations.inject(NullEnumerator.new) { |enum, type| enum + type.enum_for(:each_relation, self, directed) }.
		enum_uniq { |obj| obj }.
		each(&iterator)
	end

	# Add a new relation
	def add_child_object(to, type, info = nil)
	    relations << type
	    to.relations << type
	    type.add_child(self, to, info)
	end

	# Remove relations where self is a parent
	def remove_child_object(to = nil, type = nil)
	    apply_selection(type, relations, :each) do |type|
		apply_selection(to, self, :each_child_object, type) do |to|
		    type.remove_child(self, to)
		end
	    end
	end

	# Remove relations where self is a child
	def remove_parent_object(to = nil, type = nil)
	    apply_selection(type, relations, :each) do |type|
		apply_selection(to, self, :each_parent_object, type) do |to|
		    type.remove_parent(self, to)
		end
	    end
	end

	# Remove all relations that point to or come from +with+
	# If with is null, it removes all relations +self+ is
	# part of
	def remove_relations(to = nil, type = nil)
	    remove_child_object(to, type)
	    remove_parent_object(to, type)
	end

	def apply_selection(object, container, enumerator, *args, &iterator)
	    if object
		yield(object)
	    else
		container.send(enumerator, &iterator)
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
	    attribute(:subsets) { Array.new }
	    def relation_type; self end

	    def add_child(from, to, info)
		to.parents[relation_type] << from
		from.children[relation_type][to] = info
	    end
	    def remove_child(from, to)
		to.parents[relation_type].delete(from)
		from.children[relation_type].delete(to)
	    end
	    def child_object?(of, obj)
		of.children[relation_type].has_key?(obj) ||
		    subsets.find { |mod| mod.child_object?(of, obj) }
	    end

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

	    def each_parent_object(of, &iterator)
		of.parents[relation_type].each(&iterator)
		subsets.each { |mod| mod.each_parent_object(of, &iterator) }
	    end
	    def each_child_object(of, &iterator)
		of.children[relation_type].each_key(&iterator)
		subsets.each { |mod| mod.each_child_object(of, &iterator) }
	    end
	    
	    # Defines enumerators in the node objects for this relationship. 
	    # It defines each_#{parent} and each_#{child}. Set either to nil
	    # to disable the definition
	    def parent_enumerator(name); @parent_enumerator_name = name end
	    def relation_name(new_name = nil)
		if new_name
		    @relation_name = new_name 
		else
		    @relation_name
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
	    define_method(:const_missing) do |name|
		new_relation = Module.new do
		    def self.const_missing(name)
			super
		    end
		end
		relation_space.const_set(name, new_relation)
	    end

	    define_method(:new_relation_type) do |mod, block|
		mod.include DirectedRelation
		mod.class_eval(&block) if block
		mod.class_eval do
		    relation_type = self.relation_type
		    relation_name = self.relation_name || self.name.gsub(/.*::/, '').underscore.singularize
		    enumerator = "enumerate_#{relation_name}"
		    if parent_enumerator_name
			define_method_with_block("each_#{parent_enumerator_name}") do |iterator|
			    relation_type.each_parent_object(self, &iterator)
			end
		    end

		    
		    define_method_with_block "each_#{relation_name}" do |iterator|
			relation_type.each_child_object(self, &iterator)
		    end
		    define_method("add_#{relation_name}")    { |to, *info| self.add_child_object(to, relation_type, *info) }
		    define_method("remove_#{relation_name}") { |to| self.remove_child_object(to, relation_type) }
		end
		klass.include mod
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

