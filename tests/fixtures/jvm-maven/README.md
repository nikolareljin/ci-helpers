# jvm-maven fixture

A conventional two-file Maven project for `java.yml`.

`maven-surefire-plugin` is pinned at 3.5.2 on purpose. Maven's built-in
surefire is 2.12.4, which does not know about JUnit 5: the suite ran **zero**
tests and the build was green, so the leg driving a failing test through this
fixture would have proved nothing.

The old `lint_command` default, `mvn -B -DskipTests checkstyle:check`, fails on
this project with 12 violations from Sun's rules. `jvm-refuses-what-it-must`
asserts that, since it is the reason the default is now empty.
