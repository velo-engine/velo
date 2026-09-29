module serialize

import engine.core

// ComponentType — runtime information about a registered component type.
pub struct ComponentType {
pub:
	name   string
	create fn () core.IComponent = unsafe { nil }
	apply  fn (mut c core.IComponent, props map[string]Value) ! = unsafe { nil }
	dump   fn (c core.IComponent) map[string]Value              = unsafe { nil }
	fields []FieldInfo
}

// Registry — a name -> component type table, so .scene files can write `Sprite { ... }`.
// Each component needs just ONE line to register: registry.register[PlayerController]()
@[heap]
pub struct Registry {
mut:
	types map[string]ComponentType
}

pub fn new_registry() &Registry {
	return &Registry{}
}

pub fn (mut r Registry) register[T]() {
	name := core.short_type_name(T.name)
	r.types[name] = ComponentType{
		name:   name
		create: create_component[T]
		apply:  apply_component[T]
		dump:   dump_component[T]
		fields: describe_fields[T]()
	}
}

pub fn (r &Registry) get(name string) ?ComponentType {
	return r.types[name] or { return none }
}

pub fn (r &Registry) names() []string {
	mut k := r.types.keys()
	k.sort()
	return k
}

fn create_component[T]() core.IComponent {
	c := &T{}
	return c
}

fn apply_component[T](mut c core.IComponent, props map[string]Value) ! {
	if mut c is T {
		set_fields[T](mut c, props)!
		return
	}
	return error('component is not of type ${T.name}')
}

fn dump_component[T](c core.IComponent) map[string]Value {
	if c is T {
		return dump_fields[T](*c)
	}
	return map[string]Value{}
}
