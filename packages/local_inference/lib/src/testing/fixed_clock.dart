/// A clock that never moves, for the `now` parameters of the package.
library;

/// A clock that always answers [at].
DateTime Function() fixedClock(DateTime at) =>
    () => at;
