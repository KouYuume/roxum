"""Descriptor identities and deterministic Roc module names for one invocation."""
from dataclasses import dataclass
import re
from google.protobuf.descriptor_pb2 import DescriptorProto


@dataclass(frozen=True)
class Message:
    full_name: str
    roc_name: str
    file_name: str
    descriptor: DescriptorProto

    @property
    def location(self):
        return f'{self.file_name}:{self.full_name}'


def require(condition, location, reason):
    if not condition:
        raise ValueError(f'{location}: {reason}')


def index(request, reserved):
    files = {file.name: file for file in request.proto_file}
    require(len(files) == len(request.proto_file), 'request', 'duplicate file descriptors')
    targets = set(request.file_to_generate)
    require(targets, 'request', 'no files requested')
    require(len(targets) == len(request.file_to_generate), 'request', 'duplicate generation targets')
    for name in sorted(targets):
        require(name in files, name, 'missing descriptor')
        file = files[name]
        require(not file.package or re.fullmatch(r'[A-Za-z_][A-Za-z0-9_]*(?:\.[A-Za-z_][A-Za-z0-9_]*)*', file.package),
                name, 'invalid package name')
        require(len(set(file.dependency)) == len(file.dependency), name, 'duplicate imports')
        require(not file.weak_dependency, name, 'weak imports are not supported')
        public = list(file.public_dependency)
        require(len(set(public)) == len(public) and all(0 <= i < len(file.dependency) for i in public),
                name, 'invalid public import indices')
        for dependency in file.dependency:
            require(dependency in files, name, f'missing import descriptor: {dependency}')
            require(dependency in targets, name,
                    f'import {dependency} must also be listed as a generation target')

    # A standalone generated package owns its entire explicitly selected import
    # closure. Never silently emit incomplete modules or overwrite another package.
    remaining = {name: set(files[name].dependency) for name in targets}
    ready = [name for name, dependencies in remaining.items() if not dependencies]
    while ready:
        name = ready.pop()
        del remaining[name]
        for dependent, dependencies in remaining.items():
            if name in dependencies:
                dependencies.remove(name)
                if not dependencies:
                    ready.append(dependent)
    require(not remaining, 'request', 'cyclic imports: ' + ', '.join(sorted(remaining)))

    identities = {}
    modules = {}
    reserved_names = {name.lower() for name in reserved}
    for filename in sorted(targets):
        file = files[filename]
        pending = [(message, ()) for message in reversed(file.message_type)]
        while pending:
            descriptor, parents = pending.pop()
            path = (*parents, descriptor.name)
            full_name = '.' + '.'.join(filter(None, (file.package, *path)))
            location = f'{filename}:{full_name}'
            require(re.fullmatch(r'[A-Z][A-Za-z0-9]*', descriptor.name), location,
                    'message name is not a supported Roc type name')
            roc_name = ''.join(path)
            require(roc_name.lower() not in reserved_names, location,
                    'message name is not a supported Roc type name')
            duplicate = identities.get(full_name)
            require(duplicate is None, location,
                    'duplicate message identity'
                    + (f' (already in {duplicate.file_name})' if duplicate else ''))
            previous = modules.get(roc_name.lower())
            require(previous is None, location,
                    f'message module name collision: {roc_name}'
                    + (f' conflicts with {previous.full_name} in {previous.file_name}' if previous else ''))
            symbol = Message(full_name, roc_name, filename, descriptor)
            identities[full_name] = symbol
            modules[roc_name.lower()] = symbol
            pending.extend((nested, path) for nested in reversed(descriptor.nested_type))
    require(identities, 'request', 'no messages requested')
    return files, sorted(identities.values(), key=lambda symbol: symbol.roc_name)
