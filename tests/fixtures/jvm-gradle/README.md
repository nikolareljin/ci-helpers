# jvm-gradle fixture

A plain Kotlin/JVM Gradle project, deliberately **not** an Android one: the
point is what a Kotlin repository that is not an app meets when it adopts
`kotlin.yml`. `jvm-refuses-what-it-must` asserts that `lint` and
`assembleDebug` are absent here, which is why those stopped being the defaults.

`java-gradle.yml` runs against the same tree, since its defaults
(`check -x test`, `test`, `build`) are the ones this project has.

The wrapper is committed, as it is in any Gradle repository: `./gradlew` is
what both presets call, and a fixture without one would exercise a path no
consumer uses.
