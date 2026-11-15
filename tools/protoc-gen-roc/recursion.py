"""Co-locate cyclic message components without introducing cyclic Roc imports."""
from schema import require


def layout(messages, identities):
    graph = {m.full_name: sorted({f.type_name for f in m.descriptor.field if f.type == 11})
             for m in messages if not m.is_enum}
    reverse = {name: [] for name in graph}
    for name, edges in graph.items():
        for edge in edges:
            reverse[edge].append(name)
    seen, order = set(), []
    for name in sorted(graph):
        stack = [(name, False)]
        while stack:
            node, finish = stack.pop()
            if finish:
                order.append(node)
            elif node not in seen:
                seen.add(node)
                stack.append((node, True))
                stack.extend((edge, False) for edge in reversed(graph[node]) if edge not in seen)
    seen, components = set(), {}
    occupied = {m.roc_name.lower() for m in messages}
    for name in reversed(order):
        if name in seen:
            continue
        members, pending = [], [name]
        while pending:
            node = pending.pop()
            if node in seen:
                continue
            seen.add(node)
            members.append(node)
            pending.extend(reverse[node])
        if len(members) == 1 and name not in graph[name]:
            continue
        module = min(identities[n].roc_name for n in members) + 'Recursive'
        require(module.lower() not in occupied, identities[name].location,
                'recursive component module name collision: ' + module)
        occupied.add(module.lower())
        for member in members:
            components[member] = module
    paths = {m.full_name: (components[m.full_name] + '.' if m.full_name in components else '') + m.roc_name
             for m in messages}
    return paths, components


def boxed(owner, field, components):
    return (field.type == 11 and field.label != 3 and owner.full_name in components
            and components.get(field.type_name) == components[owner.full_name])


def equality_supported(symbol, identities, components):
    pending, seen = [symbol.full_name], set()
    while pending:
        node = pending.pop()
        if node in components:
            return False
        if node in seen:
            continue
        seen.add(node)
        target = identities[node]
        if not target.is_enum:
            pending.extend(f.type_name for f in target.descriptor.field if f.type == 11)
    return True
