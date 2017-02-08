import 'package:source_span/source_span.dart';

import "compile_metadata.dart"
    show
        CompileTypeMetadata,
        CompileTokenMap,
        CompileQueryMetadata,
        CompileTokenMetadata,
        CompileProviderMetadata,
        CompileDirectiveMetadata,
        CompileDiDependencyMetadata;
import "identifiers.dart" show Identifiers, identifierToken;
import "parse_util.dart" show ParseError;
import "template_ast.dart"
    show
        ReferenceAst,
        AttrAst,
        DirectiveAst,
        ProviderAst,
        ProviderAstType,
        ElementProviderUsage;

class ProviderError extends ParseError {
  ProviderError(String message, SourceSpan span) : super(span, message);
}

/// Per component level context used to parse template using
/// TemplateParseVisitor.
class ProviderViewContext {
  final CompileDirectiveMetadata component;
  final SourceSpan sourceSpan;

  /// List of queries defined on the component used to detect which providers
  /// should be eagerly created at runtime initialization.
  CompileTokenMap<List<CompileQueryMetadata>> viewQueries;

  /// List of tokens provided by component.
  CompileTokenMap<bool> viewProviders;
  List<ProviderError> errors = [];

  ProviderViewContext(this.component, this.sourceSpan) {
    viewQueries = _getViewQueries(component);
    viewProviders = new CompileTokenMap<bool>();
    List<CompileProviderMetadata> normalizedViewProviders =
        _normalizeProviders(component.viewProviders, sourceSpan, errors);
    // Deduplicate providers by token.
    for (CompileProviderMetadata provider in normalizedViewProviders) {
      if (viewProviders.get(provider.token) == null) {
        viewProviders.add(provider.token, true);
      }
    }
  }
}

class ProviderElementContext implements ElementProviderUsage {
  final ProviderViewContext _rootProviderContext;
  final ProviderElementContext _parent;
  // True if parent is template or template has bindings.
  final bool _isViewRoot;
  final List<DirectiveAst> _directiveAsts;
  SourceSpan _sourceSpan;
  CompileTokenMap<List<CompileQueryMetadata>> _contentQueries;
  var _transformedProviders = new CompileTokenMap<ProviderAst>();
  var _seenProviders = new CompileTokenMap<bool>();
  CompileTokenMap<ProviderAst> _allProviders;
  Map<String, String> _attrs;
  bool _requiresViewContainer = false;

  ProviderElementContext(
      this._rootProviderContext,
      this._parent,
      this._isViewRoot,
      this._directiveAsts,
      List<AttrAst> attrs,
      List<ReferenceAst> refs,
      this._sourceSpan) {
    this._attrs = {};
    for (var attrAst in attrs) {
      _attrs[attrAst.name] = attrAst.value;
    }
    var directivesMeta =
        _directiveAsts.map((directiveAst) => directiveAst.directive).toList();
    // Make a list of all providers required by union of all directives
    // including components themselves.
    _allProviders = _resolveProvidersFromDirectives(
        directivesMeta, _sourceSpan, _rootProviderContext.errors);
    // Get content queries since we need to eagerly create providers to serve
    // values for component @Query at ngOnInit time.
    _contentQueries = _getContentQueries(directivesMeta);
    var queriedTokens = new CompileTokenMap<bool>();
    for (var provider in _allProviders.values) {
      _addQueryReadsTo(provider.token, queriedTokens);
    }
    // For each #ref, add the read type as a token to queries.
    for (ReferenceAst refAst in refs) {
      _addQueryReadsTo(
          new CompileTokenMetadata(value: refAst.name), queriedTokens);
    }
    // If any content query asks to read ViewContainerRef, mark
    // ProviderElementContext to require view container.
    if (queriedTokens.get(identifierToken(Identifiers.ViewContainerRef)) !=
        null) {
      _requiresViewContainer = true;
    }
    // Create the providers that we know are eager first.
    for (var provider in _allProviders.values) {
      var eager = provider.eager || queriedTokens.get(provider.token) != null;
      if (eager) {
        _getOrCreateLocalProvider(provider.providerType, provider.token,
            eager: true);
      }
    }
  }

  void afterElement() {
    // Collect lazy providers (provider itself not eager and not queried).
    for (var provider in _allProviders.values) {
      _getOrCreateLocalProvider(provider.providerType, provider.token,
          eager: false);
    }
  }

  List<ProviderAst> get transformProviders {
    return _transformedProviders.values;
  }

  List<DirectiveAst> get transformedDirectiveAsts {
    var sortedProviderTypes = _transformedProviders.values
        .map((provider) => provider.token.identifier)
        .toList();
    var sortedDirectives = new List<DirectiveAst>.from(_directiveAsts);
    sortedDirectives.sort((dir1, dir2) =>
        sortedProviderTypes.indexOf(dir1.directive.type) -
        sortedProviderTypes.indexOf(dir2.directive.type));
    return sortedDirectives;
  }

  bool get requiresViewContainer => _requiresViewContainer;

  bool hasNonLocalRequest(ProviderAst providerAst) => true;

  void _addQueryReadsTo(
      CompileTokenMetadata token, CompileTokenMap<bool> queryReadTokens) {
    for (var query in _getQueriesFor(token)) {
      var queryReadToken = query.read ?? token;
      if (queryReadTokens.get(queryReadToken) == null) {
        queryReadTokens.add(queryReadToken, true);
      }
    }
  }

  List<CompileQueryMetadata> _getQueriesFor(CompileTokenMetadata token) {
    List<CompileQueryMetadata> result = [];
    ProviderElementContext currentEl = this;
    var distance = 0;
    List<CompileQueryMetadata> queries;
    while (!identical(currentEl, null)) {
      queries = currentEl._contentQueries.get(token);
      if (queries != null) {
        result.addAll(queries
            .where((query) => query.descendants || distance <= 1)
            .toList());
      }
      if (currentEl._directiveAsts.isNotEmpty) {
        distance++;
      }
      currentEl = currentEl._parent;
    }
    queries = _rootProviderContext.viewQueries.get(token);
    if (queries != null) {
      result.addAll(queries);
    }
    return result;
  }

  ProviderAst _getOrCreateLocalProvider(
      ProviderAstType requestingProviderType, CompileTokenMetadata token,
      {bool eager}) {
    var resolvedProvider = _allProviders.get(token);
    if (resolvedProvider == null ||
        (((requestingProviderType == ProviderAstType.Directive) ||
                (requestingProviderType == ProviderAstType.PublicService)) &&
            (resolvedProvider.providerType ==
                ProviderAstType.PrivateService)) ||
        (((requestingProviderType == ProviderAstType.PrivateService) ||
                (requestingProviderType == ProviderAstType.PublicService)) &&
            (resolvedProvider.providerType == ProviderAstType.Builtin))) {
      return null;
    }
    var transformedProviderAst = _transformedProviders.get(token);
    if (transformedProviderAst != null) {
      return transformedProviderAst;
    }
    if (_seenProviders.get(token) != null) {
      _rootProviderContext.errors.add(new ProviderError(
          'Cannot instantiate cyclic dependency! ${token.name}',
          this._sourceSpan));
      return null;
    }
    _seenProviders.add(token, true);

    // For this token, transform and collect list of providers,
    // List will have length > 1 if multi:true and we have multiple providers.
    var transformedProviders = <CompileProviderMetadata>[];
    for (var provider in resolvedProvider.providers) {
      var transformedUseValue = provider.useValue;
      var transformedUseExisting = provider.useExisting;
      List<CompileDiDependencyMetadata> transformedDeps;
      if (provider.useExisting != null) {
        var existingDiDep = _getDependency(
            resolvedProvider.providerType,
            new CompileDiDependencyMetadata(token: provider.useExisting),
            eager);
        if (existingDiDep.token != null) {
          transformedUseExisting = existingDiDep.token;
        } else {
          transformedUseExisting = null;
          transformedUseValue = existingDiDep.value;
        }
      } else if (provider.useFactory != null) {
        var dependencies = provider.deps ?? provider.useFactory.diDeps;
        transformedDeps = [];
        for (var dep in dependencies) {
          transformedDeps
              .add(_getDependency(resolvedProvider.providerType, dep, eager));
        }
      } else if (provider.useClass != null) {
        var dependencies = provider.deps ?? provider.useClass.diDeps;
        transformedDeps = [];
        for (var dep in dependencies) {
          transformedDeps
              .add(_getDependency(resolvedProvider.providerType, dep, eager));
        }
      }
      transformedProviders.add(_transformProvider(provider,
          useExisting: transformedUseExisting,
          useValue: transformedUseValue,
          deps: transformedDeps));
    }

    /// Create a clone of the ProviderAst using new eager parameter.
    transformedProviderAst = _transformProviderAst(resolvedProvider,
        forceEager: eager, providers: transformedProviders);
    _transformedProviders.add(token, transformedProviderAst);
    return transformedProviderAst;
  }

  CompileDiDependencyMetadata _getLocalDependency(
      ProviderAstType requestingProviderType, CompileDiDependencyMetadata dep,
      [bool eager = null]) {
    if (dep.isAttribute) {
      var attrValue = this._attrs[dep.token.value];
      return new CompileDiDependencyMetadata(isValue: true, value: attrValue);
    }
    if (dep.token != null) {
      // access built-ins
      if ((requestingProviderType == ProviderAstType.Directive ||
          requestingProviderType == ProviderAstType.Component)) {
        if (dep.token.equalsTo(identifierToken(Identifiers.ElementRef)) ||
            dep.token
                .equalsTo(identifierToken(Identifiers.ChangeDetectorRef)) ||
            dep.token.equalsTo(identifierToken(Identifiers.TemplateRef))) {
          return dep;
        }
        if (dep.token.equalsTo(identifierToken(Identifiers.ViewContainerRef))) {
          _requiresViewContainer = true;
        }
      }
      // access the injector
      if (dep.token.equalsTo(identifierToken(Identifiers.Injector))) {
        return dep;
      }
      // access providers
      if (_getOrCreateLocalProvider(requestingProviderType, dep.token,
              eager: eager) !=
          null) {
        return dep;
      }
    }
    return null;
  }

  CompileDiDependencyMetadata _getDependency(
      ProviderAstType requestingProviderType, CompileDiDependencyMetadata dep,
      [bool eager = null]) {
    ProviderElementContext currElement = this;
    bool currEager = eager;
    CompileDiDependencyMetadata result;
    if (!dep.isSkipSelf) {
      result = _getLocalDependency(requestingProviderType, dep, eager);
    }
    if (dep.isSelf) {
      if (result == null && dep.isOptional) {
        result = new CompileDiDependencyMetadata(isValue: true, value: null);
      }
    } else {
      // check parent elements
      while (result == null && currElement._parent != null) {
        var prevElement = currElement;
        currElement = currElement._parent;
        if (prevElement._isViewRoot) {
          currEager = false;
        }
        result = currElement._getLocalDependency(
            ProviderAstType.PublicService, dep, currEager);
      }
      // check @Host restriction
      if (result == null) {
        if (!dep.isHost ||
            _rootProviderContext.component.type.isHost ||
            identifierToken(_rootProviderContext.component.type)
                .equalsTo(dep.token) ||
            _rootProviderContext.viewProviders.get(dep.token) != null) {
          result = dep;
        } else {
          result = dep.isOptional
              ? result =
                  new CompileDiDependencyMetadata(isValue: true, value: null)
              : null;
        }
      }
    }
    if (result == null) {
      _rootProviderContext.errors.add(new ProviderError(
          'No provider for ${dep.token.name}', this._sourceSpan));
    }
    return result;
  }
}

CompileProviderMetadata _transformProvider(CompileProviderMetadata provider,
    {CompileTokenMetadata useExisting,
    dynamic useValue,
    List<CompileDiDependencyMetadata> deps}) {
  return new CompileProviderMetadata(
      token: provider.token,
      useClass: provider.useClass,
      useExisting: useExisting,
      useFactory: provider.useFactory,
      useValue: useValue,
      useProperty: provider.useProperty,
      deps: deps,
      multi: provider.multi);
}

/// Creates a new provider ast node by overriding eager and providers members
/// of existing ProviderAst.
ProviderAst _transformProviderAst(ProviderAst provider,
    {bool forceEager, List<CompileProviderMetadata> providers}) {
  return new ProviderAst(
    provider.token,
    provider.multiProvider,
    providers,
    provider.providerType,
    provider.sourceSpan,
    eager: provider.eager || forceEager,
  );
}

// Flattens list of lists of providers and converts entries that contain Type to
// CompileProviderMetadata with useClass.
List<CompileProviderMetadata> _normalizeProviders(
    List<
        dynamic /* CompileProviderMetadata | CompileTypeMetadata | List < dynamic > */ > providers,
    SourceSpan sourceSpan,
    List<ParseError> targetErrors,
    [List<CompileProviderMetadata> targetProviders = null]) {
  if (targetProviders == null) {
    targetProviders = [];
  }
  if (providers != null) {
    for (var provider in providers) {
      if (provider is List) {
        _normalizeProviders(
            provider, sourceSpan, targetErrors, targetProviders);
      } else {
        CompileProviderMetadata normalizeProvider;
        if (provider is CompileProviderMetadata) {
          normalizeProvider = provider;
        } else if (provider is CompileTypeMetadata) {
          normalizeProvider = new CompileProviderMetadata(
              token: new CompileTokenMetadata(identifier: provider),
              useClass: provider);
        } else {
          targetErrors.add(
              new ProviderError('Unknown provider type $provider', sourceSpan));
        }
        if (normalizeProvider != null) {
          targetProviders.add(normalizeProvider);
        }
      }
    }
  }
  return targetProviders;
}

/// Creates a ProviderAst for each directive and then resolves
/// each provider for the component followed by providers for directives.
CompileTokenMap<ProviderAst> _resolveProvidersFromDirectives(
    List<CompileDirectiveMetadata> directives,
    SourceSpan sourceSpan,
    List<ParseError> targetErrors) {
  var providersByToken = new CompileTokenMap<ProviderAst>();
  for (CompileDirectiveMetadata directive in directives) {
    var dirProvider = new CompileProviderMetadata(
        token: new CompileTokenMetadata(identifier: directive.type),
        useClass: directive.type);
    _resolveProviders(
      [dirProvider],
      directive.isComponent
          ? ProviderAstType.Component
          : ProviderAstType.Directive,
      sourceSpan,
      targetErrors,
      providersByToken,
      eager: true,
    );
  }
  // Note: directives need to be able to overwrite providers of a component!
  var directivesWithComponentFirst =
      (new List.from(directives.where((dir) => dir.isComponent).toList())
        ..addAll(directives.where((dir) => !dir.isComponent).toList()));
  directivesWithComponentFirst.forEach((directive) {
    _resolveProviders(
        _normalizeProviders(directive.providers, sourceSpan, targetErrors),
        ProviderAstType.PublicService,
        sourceSpan,
        targetErrors,
        providersByToken,
        eager: false);
    _resolveProviders(
        _normalizeProviders(directive.viewProviders, sourceSpan, targetErrors),
        ProviderAstType.PrivateService,
        sourceSpan,
        targetErrors,
        providersByToken,
        eager: false);
  });
  return providersByToken;
}

// Updates tokenMap by creating new ProviderAst or by adding/replacing new entry
// for existing ProviderAst.
void _resolveProviders(
    List<CompileProviderMetadata> providers,
    ProviderAstType providerType,
    SourceSpan sourceSpan,
    List<ParseError> targetErrors,
    CompileTokenMap<ProviderAst> targetProvidersByToken,
    {bool eager}) {
  for (var provider in providers) {
    var resolvedProvider = targetProvidersByToken.get(provider.token);
    if (resolvedProvider != null &&
        !identical(resolvedProvider.multiProvider, provider.multi)) {
      targetErrors.add(new ProviderError(
          'Mixing multi and non multi provider is not possible for token '
          '${resolvedProvider.token.name}',
          sourceSpan));
    }
    if (resolvedProvider == null) {
      resolvedProvider = new ProviderAst(
          provider.token, provider.multi, [provider], providerType, sourceSpan,
          eager: eager);
      targetProvidersByToken.add(provider.token, resolvedProvider);
    } else {
      if (!provider.multi) {
        resolvedProvider.providers.clear();
      }
      resolvedProvider.providers.add(provider);
    }
  }
}

CompileTokenMap<List<CompileQueryMetadata>> _getViewQueries(
    CompileDirectiveMetadata component) {
  var viewQueries = new CompileTokenMap<List<CompileQueryMetadata>>();
  if (component.viewQueries == null) return viewQueries;
  for (CompileQueryMetadata query in component.viewQueries) {
    _addQueryToTokenMap(viewQueries, query);
  }
  return viewQueries;
}

CompileTokenMap<List<CompileQueryMetadata>> _getContentQueries(
    List<CompileDirectiveMetadata> directives) {
  var contentQueries = new CompileTokenMap<List<CompileQueryMetadata>>();
  directives.forEach((directive) {
    if (directive.queries != null) {
      directive.queries
          .forEach((query) => _addQueryToTokenMap(contentQueries, query));
    }
  });
  return contentQueries;
}

void _addQueryToTokenMap(CompileTokenMap<List<CompileQueryMetadata>> map,
    CompileQueryMetadata query) {
  query.selectors.forEach((CompileTokenMetadata token) {
    var entry = map.get(token);
    if (entry == null) {
      entry = [];
      map.add(token, entry);
    }
    entry.add(query);
  });
}
