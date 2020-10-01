# CPEE Logging XES YAML

To install the logging service go to the commandline

```bash
 gem install cpee-logging-xes-yaml
 cpee-logging-xes-yaml log
 cd log
 ./log start
```

The service is running under port 9299. If this port has to be changed (or the
host, or local-only access, ...), create a file log.conf and add one
or many of the following yaml keys:

```yaml
 :port: 9250
 :host: cpee.org
 :bind: 127.0.0.1
 :log_dir: /var/log/cpee
```

To connec the cpee to the log, one of two things can be done: (1) add a handler to
a testset/template:

```xml
  <handlers>
    <handler url="http://localhost:9299/">
      <events topic="activity">calling,receiving,done</events>
      <events topic="dataelements">change</events>
      <events topic="endpoints">change</events>
      <events topic="attributes">change</events>
      <events topic="task">instantiation</events>
    </handler>
  </handlers>
```

(2) add a default handler to the cpee by adding

```ruby
Riddl::Server.new(CPEE::SERVER, options) do
  ...
  @riddl_opts[:notifications_init] = File.join(__dir__,'resources','notifications')
  ...
  use CPEE::implementation(@riddl_opts)
end.loop!
```

to the server (or alternatively to a log.conf with :notification_init
beeing a top-level yaml key). Then add a subscription file to
notifications/logging/subscription.xml

```xml
<subscription xmlns="http://riddl.org/ns/common-patterns/notifications-producer/2.0" url="http://localhost:9299/">
  <topic id="activity">
    <event>calling</event>
    <event>receiving</event>
    <event>done</event>
  </topic>
  <topic id="dataelements">
    <event>change</event>
  </topic>
  <topic id="endpoints">
    <event>change</event>
  </topic>
  <topic id="attributes">
    <event>change</event>
  </topic>
  <topic id="task">
    <event>instantiation</event>
  </topic>
</subscription>
```

