# Deployment Techniques

## 1. Recreate Deployment

### Concept
Imagine you have one shop selling version 1 of a product. To sell version 2, you **close the shop, remove everything, and reopen it** with the new product. During the closed period, no customers can buy anything. That's a Recreate Deployment — the simplest possible strategy.

### How It Works
1. Stop all running instances of the old application version (v1).
2. Wait until they are fully terminated.
3. Deploy and start the new version (v2).
4. Traffic resumes only once v2 is healthy.

```
[v1 running] --STOP--> [nothing running - DOWNTIME] --START--> [v2 running]
```

### Why and When to Use It
Recreate is used when:
- The application **cannot run two versions simultaneously** (e.g., a database schema migration that breaks backward compatibility).
- You're working with **single-instance, non-critical systems** (internal tools, batch jobs, dev/staging environments).
- Simplicity matters more than availability.

It is common in **Kubernetes** as a `Deployment` strategy type:

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: order-service
spec:
  replicas: 3
  strategy:
    type: Recreate
  template:
    spec:
      containers:
        - name: order-service
          image: order-service:v2
```

Kubernetes will terminate **all** old pods before creating new ones — guaranteeing downtime but avoiding version-mixing issues.

### Engineering Trade-offs
evaluate Recreate deployment through these lenses:

- **Consistency over Availability**: In CAP-theorem-adjacent thinking, Recreate sacrifices availability to guarantee that only one version of the code (and therefore one version of business logic/data contracts) is ever active.
- **Database Migration Safety**: If a migration is destructive (e.g., dropping a column that v1 depends on), Recreate is often the *only* safe option unless you use the **expand-contract pattern** to avoid downtime.
- **SLA Impact**: Downtime must be quantified — e.g., "deployment takes 45 seconds, twice a week, during a maintenance window" — and communicated via error budgets (SRE practice).
- **Alternative when downtime is unacceptable**: Use the expand-contract (parallel change) pattern combined with Rolling/Blue-Green so schema changes are backward-compatible during the transition.

**Java Example — A simple readiness/liveness gate that would block traffic during Recreate:**

```java
@RestController
public class HealthController {

    private final AtomicBoolean isReady = new AtomicBoolean(false);

    @PostConstruct
    public void onStartup() {
        // Simulate warm-up: DB connection pool, cache pre-loading, etc.
        warmUpResources();
        isReady.set(true);
    }

    @GetMapping("/health/ready")
    public ResponseEntity<String> readiness() {
        return isReady.get()
                ? ResponseEntity.ok("READY")
                : ResponseEntity.status(503).body("NOT_READY");
    }

    private void warmUpResources() {
        // e.g., connectionPool.initialize(); cache.preload();
    }
}
```

During a Recreate deployment, the orchestrator polls `/health/ready` — only once this returns `200 OK` does traffic resume, minimizing the "downtime tail."

| Aspect | Detail |
|---|---|
| Downtime | Yes (full outage during switch) |
| Rollback | Easy — redeploy previous image |
| Complexity | Very low |
| Best for | Dev/staging, breaking schema changes, low-traffic internal apps |

---

## 2. Rolling Deployment

### Concept
Imagine a restaurant with 5 chefs. Instead of firing all 5 and hiring 5 new ones at once (which shuts the kitchen down), you **replace one chef at a time**. The kitchen never stops serving food. This is Rolling Deployment.

### How It Works
1. Take one instance (or a small batch) out of the load balancer pool.
2. Update it to the new version.
3. Health-check it; if healthy, add it back to the pool.
4. Repeat for the next instance until all are updated.

```
[v1][v1][v1] -> [v2][v1][v1] -> [v2][v2][v1] -> [v2][v2][v2]
```

### Configuration
This is Kubernetes' **default** deployment strategy:

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: payment-service
spec:
  replicas: 6
  strategy:
    type: RollingUpdate
    rollingUpdate:
      maxUnavailable: 1   # how many pods can be down at once
      maxSurge: 2         # how many extra pods can be created temporarily
  template:
    spec:
      containers:
        - name: payment-service
          image: payment-service:v2
          readinessProbe:
            httpGet:
              path: /health/ready
              port: 8080
            initialDelaySeconds: 5
            periodSeconds: 10
```

- `maxUnavailable`: controls how much capacity can drop during the rollout.
- `maxSurge`: controls how many *extra* pods can temporarily exist above the desired replica count.

### The Hard Problem: Version Coexistence
The real engineering challenge in Rolling Deployment isn't the orchestration — it's that **for a period of time, v1 and v2 run simultaneously**, both talking to the same database and possibly the same message queue. A engineer must guarantee:

1. **Backward-compatible API contracts**: v2 must be able to serve requests that were shaped for v1 assumptions (and vice versa), at least for the rollout window.
2. **Backward-compatible database schema**: Use the **expand-contract pattern**:
   - *Expand*: Add new column/table without removing the old one.
   - *Migrate*: Deploy code (v2) that can read/write both old and new schema.
   - *Contract*: Once 100% rolled out, remove old schema in a later deployment.
3. **Idempotency in message consumers**: If v1 and v2 consumers both read from Kafka/RabbitMQ, ensure processing is idempotent — a message might be retried by a pod that got killed mid-processing.
4. **Session affinity**: If the app is stateful (e.g., sticky sessions), a rolling restart can drop in-memory session data unless sessions are externalized (e.g., to Redis).

**Java Example — externalizing session state so rolling restarts don't lose data:**

```java
@Configuration
@EnableRedisHttpSession(maxInactiveIntervalInSeconds = 1800)
public class SessionConfig {

    @Bean
    public LettuceConnectionFactory connectionFactory() {
        return new LettuceConnectionFactory(
                new RedisStandaloneConfiguration("redis-cluster", 6379));
    }
}
```

By moving session state out of the JVM heap and into Redis, any instance (v1 or v2) can serve any user's request — a prerequisite for safe rolling updates of stateful services.

**Graceful shutdown — critical for Rolling deployments:**

```java
@Component
public class GracefulShutdown {

    @PreDestroy
    public void onShutdown() {
        // Stop accepting new work, but let in-flight requests finish
        executorService.shutdown();
        try {
            if (!executorService.awaitTermination(30, TimeUnit.SECONDS)) {
                executorService.shutdownNow();
            }
        } catch (InterruptedException e) {
            executorService.shutdownNow();
        }
    }
}
```

Without graceful shutdown, a rolling update can **drop in-flight requests** when Kubernetes sends `SIGTERM` to a pod being replaced.

| Aspect | Detail |
|---|---|
| Downtime | No (capacity dips slightly) |
| Rollback | Moderate — must roll forward/backward instance-by-instance |
| Complexity | Medium |
| Best for | Stateless microservices, standard production rollouts |

---

## 3. Blue-Green Deployment

### Concept
Think of two identical apartments — **Blue** (currently lived in) and **Green** (freshly renovated with new furniture). Once Green is fully ready and inspected, you simply **switch which apartment's address people are told to visit**. No mixing, no gradual transition — an instant, total switch.

### How It Works
1. **Blue** environment serves 100% of production traffic (current version).
2. Deploy the new version to an identical, isolated **Green** environment.
3. Test Green thoroughly (smoke tests, synthetic transactions) while it receives zero real traffic.
4. Flip the router/load balancer/DNS to send 100% of traffic to Green.
5. Keep Blue idle (not deleted) as an instant rollback target.

```
              ┌─────────────┐
Traffic ────► │   Router    │
              └──────┬──────┘
                     │  (before switch: 100% → Blue)
          ┌──────────┴───────────┐
          ▼                      ▼
     ┌─────────┐             ┌─────────┐
     │  BLUE   │             │  GREEN  │
     │  (v1)   │             │  (v2)   │
     └─────────┘             └─────────┘
     (after switch: 100% → Green, Blue kept warm)
```

### Implementation Patterns
Blue-Green can be implemented at different layers:

| Layer | Mechanism |
|---|---|
| DNS | Update DNS record to point to Green's IP (slow due to TTL/caching) |
| Load Balancer | Switch target group (AWS ALB, NGINX upstream swap) — instant |
| Kubernetes | Use two Deployments + a Service selector swap |
| Service Mesh | Istio VirtualService weight change (0/100 → 100/0) |

**Kubernetes example using a Service selector swap:**

```yaml
# Both deployments run simultaneously
apiVersion: apps/v1
kind: Deployment
metadata:
  name: app-blue
spec:
  replicas: 4
  selector:
    matchLabels: { app: myapp, version: blue }
  template:
    metadata:
      labels: { app: myapp, version: blue }
    spec:
      containers: [{ name: app, image: myapp:v1 }]
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: app-green
spec:
  replicas: 4
  selector:
    matchLabels: { app: myapp, version: green }
  template:
    metadata:
      labels: { app: myapp, version: green }
    spec:
      containers: [{ name: app, image: myapp:v2 }]
---
# The Service selector is what actually controls traffic
apiVersion: v1
kind: Service
metadata:
  name: app-service
spec:
  selector:
    app: myapp
    version: blue   # <-- change to "green" to cut over instantly
  ports:
    - port: 80
```

### The Real Engineering Challenges
1. **Cost**: You run **2x infrastructure** during the transition window — a engineer must justify this against the business value of near-zero-downtime, instant rollback.
2. **Database compatibility**: Both Blue and Green typically share **one database**. This means:
   - Schema changes must follow expand-contract (same issue as Rolling).
   - Any rollback to Blue after Green has written new-format data can cause **data loss or corruption** — this is the most dangerous hidden trap of Blue-Green.
3. **Stateful connections**: Long-lived connections (WebSockets, gRPC streams) held by clients to Blue won't automatically move to Green — you need connection draining.
4. **Cache invalidation**: If Green uses a different cache key schema, a shared cache (e.g., Redis) can serve **stale or incompatible data** to Blue during the transition.
5. **Smoke-testing Green safely**: Route a synthetic "shadow user" or internal QA traffic to Green via a header-based routing rule before the full switch.

**Java Example — Header-based routing rule check used during pre-cutover testing (Spring Boot filter):**

```java
@Component
public class ColorRoutingFilter extends OncePerRequestFilter {

    @Value("${deployment.color}")
    private String currentColor; // "blue" or "green"

    @Override
    protected void doFilterInternal(HttpServletRequest request,
                                     HttpServletResponse response,
                                     FilterChain chain) throws IOException, ServletException {
        String requestedColor = request.getHeader("X-Deploy-Color");

        // Allow internal QA to explicitly target Green before public cutover
        if (requestedColor != null && !requestedColor.equalsIgnoreCase(currentColor)) {
            response.setStatus(HttpServletResponse.SC_NOT_FOUND);
            return;
        }
        chain.doFilter(request, response);
    }
}
```

**Rollback is the single biggest advantage:**

```bash
# Instant rollback — just flip the selector back
kubectl patch service app-service -p '{"spec":{"selector":{"version":"blue"}}}'
```

| Aspect | Detail |
|---|---|
| Downtime | No |
| Rollback | Very easy — instant traffic flip back to Blue |
| Complexity | Medium-High (2x infra, DB compatibility planning) |
| Best for | High-traffic production systems needing instant rollback guarantees |

---

## 4. Canary Deployment

### Beginner Concept
Named after the historical practice of miners carrying a canary bird into coal mines — if the canary got sick, miners knew danger was present before it affected them. In deployment terms: **release the new version to a small slice of real users first**. If nothing breaks, gradually expand. If something breaks, only a small percentage of users were affected.

### How It Works
1. Deploy v2 alongside v1, but route only a small % of traffic (e.g., 5%) to v2.
2. Monitor error rates, latency, and business metrics closely.
3. If healthy, gradually increase traffic to v2 (5% → 25% → 50% → 100%).
4. If unhealthy, roll back by routing 0% to v2.

```
Stage 1:  v1 = 95%   v2 = 5%
Stage 2:  v1 = 75%   v2 = 25%
Stage 3:  v1 = 50%   v2 = 50%
Stage 4:  v1 = 0%    v2 = 100%
```

### Intermediate Concept — Implementation with a Service Mesh
Canary requires **fine-grained traffic splitting**, which is why it's usually implemented with a service mesh like **Istio** or an ingress controller supporting weighted routing:

```yaml
apiVersion: networking.istio.io/v1beta1
kind: VirtualService
metadata:
  name: user-service
spec:
  hosts:
    - user-service
  http:
    - route:
        - destination:
            host: user-service
            subset: v1
          weight: 90
        - destination:
            host: user-service
            subset: v2
          weight: 10
```

### Senior-Level Concept — Automated, Metrics-Driven Canary Analysis
A senior engineer doesn't manually watch dashboards — they implement **automated canary analysis (ACA)** using tools like **Argo Rollouts**, **Flagger**, or **Spinnaker**, which:

1. Query a metrics backend (Prometheus, Datadog) for the canary's error rate, p99 latency, and CPU/memory.
2. Statistically compare canary metrics vs. the stable baseline (not just absolute thresholds — a good ACA system accounts for normal variance).
3. Automatically **promote** (increase weight) or **abort and roll back** based on predefined success criteria — no human in the loop for routine rollouts.

```yaml
# Argo Rollouts example
apiVersion: argoproj.io/v1alpha1
kind: Rollout
metadata:
  name: checkout-service
spec:
  strategy:
    canary:
      steps:
        - setWeight: 10
        - pause: { duration: 5m }
        - analysis:
            templates:
              - templateName: success-rate-check
        - setWeight: 50
        - pause: { duration: 10m }
        - setWeight: 100
```

**Key metrics a senior engineer instruments to make canary analysis meaningful:**
- **Golden Signals** (Google SRE): Latency, Traffic, Errors, Saturation.
- **Business KPIs**: e.g., checkout conversion rate — a canary can be "technically healthy" (no 500 errors) yet still be *functionally broken* (a broken "Buy" button that fails silently on the client).

**Java Example — emitting the custom metrics that feed the canary analysis (Micrometer + Prometheus):**

```java
@RestController
public class CheckoutController {

    private final Counter checkoutSuccessCounter;
    private final Counter checkoutFailureCounter;
    private final Timer checkoutLatencyTimer;

    public CheckoutController(MeterRegistry registry) {
        this.checkoutSuccessCounter = Counter.builder("checkout.success")
                .tag("version", System.getenv("APP_VERSION"))
                .register(registry);
        this.checkoutFailureCounter = Counter.builder("checkout.failure")
                .tag("version", System.getenv("APP_VERSION"))
                .register(registry);
        this.checkoutLatencyTimer = Timer.builder("checkout.latency")
                .tag("version", System.getenv("APP_VERSION"))
                .register(registry);
    }

    @PostMapping("/checkout")
    public ResponseEntity<String> checkout(@RequestBody OrderRequest request) {
        return checkoutLatencyTimer.record(() -> {
            try {
                processOrder(request);
                checkoutSuccessCounter.increment();
                return ResponseEntity.ok("Order placed");
            } catch (Exception e) {
                checkoutFailureCounter.increment();
                return ResponseEntity.status(500).body("Order failed");
            }
        });
    }
}
```

The `version` tag lets Prometheus/Argo Rollouts compare `checkout.failure{version="v2"}` against `checkout.failure{version="v1"}` in real time to decide whether to proceed or abort.

| Aspect | Detail |
|---|---|
| Downtime | No |
| Rollback | Easy — reduce canary weight to 0% |
| Complexity | High (needs traffic-splitting infra + metrics-driven automation) |
| Best for | High-risk changes, large user bases, teams with strong observability |

---

## 5. A/B Testing Deployment

### Beginner Concept
A/B testing looks similar to Canary but has a **completely different goal**. Canary asks: *"Is this new version stable/safe?"* A/B testing asks: *"Which version do users prefer, or which one performs better on a business metric?"* Different users are **intentionally and often permanently** split between versions to measure the difference — this isn't about safety, it's about **experimentation**.

### How It Works
1. Split users into cohorts — often by a **consistent hashing of user ID** (so the same user always sees the same version).
2. Version A (control) and Version B (variant) run simultaneously for an extended period (days/weeks — not minutes like canary).
3. Collect metrics: conversion rate, click-through rate, revenue per user, retention.
4. Use statistical significance testing to decide the winner.

```
User Hash % 100:
  0-49   -> Version A (control)   -- e.g., old checkout flow
  50-99  -> Version B (variant)   -- e.g., new one-click checkout
```

### Intermediate Concept — Consistent Bucketing
Unlike Canary (which shifts weight over time), A/B testing needs **stable, sticky assignment** — the same user must always see the same variant for the results to be statistically valid.

```java
@Component
public class ExperimentBucketService {

    public String getVariant(String userId, String experimentName) {
        String key = experimentName + ":" + userId;
        int bucket = Math.abs(Hashing.murmur3_32().hashString(key, StandardCharsets.UTF_8).asInt()) % 100;
        return bucket < 50 ? "CONTROL" : "VARIANT";
    }
}
```

```java
@RestController
public class CheckoutFlowController {

    private final ExperimentBucketService experimentService;

    @GetMapping("/checkout/flow")
    public ResponseEntity<String> getCheckoutFlow(@RequestHeader("X-User-Id") String userId) {
        String variant = experimentService.getVariant(userId, "new_checkout_experiment");
        if (variant.equals("VARIANT")) {
            return ResponseEntity.ok("one-click-checkout");
        }
        return ResponseEntity.ok("standard-checkout");
    }
}
```

### Senior-Level Concept — Statistical Rigor and Pitfalls
A senior engineer collaborating with data science must guard against:

1. **Sample Ratio Mismatch (SRM)**: If the intended 50/50 split actually delivers 55/45 in observed traffic, something is systematically wrong (e.g., bots skew one bucket, or a caching layer sticks users to one variant) — and **any conclusion drawn is invalid** until SRM is fixed.
2. **Statistical Power and Sample Size**: Running an A/B test too briefly, or with too few users, risks **false positives/negatives**. This requires calculating the minimum sample size upfront based on baseline conversion rate and minimum detectable effect.
3. **Peeking Problem**: Repeatedly checking results and stopping "as soon as it looks significant" inflates false-positive rates — needs sequential testing methods (e.g., mSPRT) or a pre-committed sample size/duration.
4. **Network effects / interference**: In social or marketplace apps, Version B assigned to one user can indirectly affect a Version A user (e.g., inventory contention), violating the assumption of independent observations.
5. **Infrastructure separation from Canary**: A/B testing frameworks (Optimizely, LaunchDarkly, GrowthBook, or an in-house system) are typically decoupled from the *deployment* pipeline — both A and B are already fully deployed, stable code; the "test" is a product/business decision layer, not a release-safety layer.

| Aspect | Detail |
|---|---|
| Downtime | No |
| Rollback | Easy — reassign the bucket, no redeploy needed |
| Complexity | High (statistical rigor, sticky bucketing, product analytics integration) |
| Best for | Product/UX experimentation, growth optimization — not release-safety |

---

## 6. Shadow Deployment (Mirroring)

### Beginner Concept
Imagine a trainee pilot sitting in the cockpit next to a real pilot, silently making the same decisions on a **disconnected control panel** — their decisions never actually fly the plane, but you can compare their choices to the real pilot's afterward. Shadow Deployment copies real production traffic to a new version **without that version's response ever being shown to the user**.

### How It Works
1. Real user requests hit v1 (the version of record) and the response is returned to the user as normal.
2. The **exact same request** is asynchronously copied ("mirrored") to v2.
3. v2 processes it and produces a response, but that response is **discarded or only logged** — never sent to the real user.
4. Engineers compare v1 vs v2 outputs, latency, and error rates offline.

```
User Request ──► v1 (Production) ──► Response sent to user
       │
       └────► (async copy) ──► v2 (Shadow) ──► Response LOGGED, not returned
```

### Intermediate Concept — Implementation
This is commonly done at the **infrastructure/gateway layer** so application code doesn't need to know about shadowing:

```yaml
# Istio traffic mirroring example
apiVersion: networking.istio.io/v1beta1
kind: VirtualService
metadata:
  name: search-service
spec:
  hosts:
    - search-service
  http:
    - route:
        - destination:
            host: search-service
            subset: v1
          weight: 100
      mirror:
        host: search-service
        subset: v2
      mirrorPercentage:
        value: 100.0
```

### Senior-Level Concept — Why and When Shadow Deployment Is Used
Shadow deployment is the **safest possible way to test with real production traffic and load patterns**, because it has zero user-facing risk. Senior engineers reach for it when:

1. **Rewriting a critical system** (e.g., migrating a pricing engine from a monolith to microservices) — you need confidence that the new system produces **identical outputs** under real, unpredictable production load *before* it ever serves a real response.
2. **Load/performance validation**: You want to know how v2 behaves under actual peak traffic, not synthetic load-test traffic which rarely captures real-world request diversity.
3. **Side-effect isolation is critical**: If v2 writes to a database or calls a third-party payment API, shadowing must **stub out or sandbox side effects** — you don't want to double-charge a customer's credit card because the shadow copy of the request also called Stripe. This is the single biggest engineering challenge of Shadow Deployment.

**Java Example — a shadow-safe design that isolates write side-effects using a "dry-run" execution mode:**

```java
public interface PaymentGateway {
    PaymentResult charge(PaymentRequest request);
}

@Service
public class ShadowAwarePaymentService {

    private final PaymentGateway realGateway;
    private final PaymentGateway sandboxGateway; // no real money moves

    public PaymentResult process(PaymentRequest request, boolean isShadowTraffic) {
        if (isShadowTraffic) {
            // Route to a sandbox/mock gateway — never touches real money
            return sandboxGateway.charge(request);
        }
        return realGateway.charge(request);
    }
}
```

```java
@Component
public class ShadowTrafficInterceptor implements HandlerInterceptor {

    @Override
    public boolean preHandle(HttpServletRequest request, HttpServletResponse response, Object handler) {
        boolean isShadow = "true".equals(request.getHeader("X-Shadow-Request"));
        ShadowContext.set(isShadow); // ThreadLocal flag read downstream by services
        return true;
    }
}
```

4. **Comparison tooling ("diffing")**: Senior teams build automated diffing pipelines (e.g., using a tool like Diffy, originally built at Twitter) that log and highlight discrepancies between v1 and v2 responses for the same request, categorizing them as noise (timestamps, random IDs) vs. genuine bugs.

| Aspect | Detail |
|---|---|
| Downtime | No |
| Rollback | Not usually needed — shadow never serves real users |
| Complexity | High (must isolate all side effects: payments, emails, DB writes) |
| Best for | High-risk rewrites, validating new systems against real traffic before cutover |

---

## 7. Feature Flag (Toggle) Deployment

### Beginner Concept
Think of a light switch on a wall that's already wired into the house, but you choose **when to flip it on**. Feature Flag Deployment separates two things that are normally bundled together: **deploying code** and **releasing a feature to users**. The code for a new feature can be sitting live in production, fully deployed, but completely invisible/inactive until a flag is turned on — no redeploy needed to release it.

### How It Works
1. Developer wraps new functionality in a conditional check tied to a **feature flag** (a boolean or percentage-based toggle, usually managed in a config service or external platform).
2. The code is deployed to production **disabled by default** — deployment and release become two decoupled events.
3. The flag is turned on for specific users, a percentage of traffic, or everyone — instantly, without a new deployment.
4. If something goes wrong, the flag is switched off **immediately** — often faster than any other rollback method, since no infrastructure change is needed at all.

```
Deploy code (flag = OFF) ──► Code is live but invisible
        │
        ▼
Flip flag to ON for 5% ──► 25% ──► 100%     (all without redeploying)
        │
        ▼
Bug found? Flip flag OFF instantly — code stays deployed, feature hidden again
```

### Intermediate Concept — Basic Implementation
The simplest version is an environment-variable or config-driven flag:

```java
@RestController
public class RecommendationController {

    @Value("${feature.new-recommendation-engine.enabled:false}")
    private boolean newEngineEnabled;

    private final RecommendationEngine legacyEngine;
    private final RecommendationEngine newEngine;

    @GetMapping("/recommendations/{userId}")
    public List<Product> getRecommendations(@PathVariable String userId) {
        RecommendationEngine engine = newEngineEnabled ? newEngine : legacyEngine;
        return engine.recommend(userId);
    }
}
```

The limitation: changing `feature.new-recommendation-engine.enabled` still typically requires a config reload or restart, which is why production-grade systems use a **dynamic feature flag platform**.

### Senior-Level Concept — Production-Grade Feature Flag Architecture
Senior engineers use dedicated platforms (**LaunchDarkly, Unleash, Flagsmith, Split.io**, or an in-house system) because real feature-flag systems need:

1. **Real-time updates without restarts**: Flags are evaluated via an SDK that streams changes from a control plane (via SSE/websocket/polling), so toggling in a dashboard takes effect within seconds across every running instance.
2. **Targeting rules, not just booleans**: e.g., "enable for internal employees AND 10% of US users AND NOT users on the legacy mobile app version."
3. **Kill switches as a first-class operational tool**: Feature flags become the **fastest possible rollback mechanism** — faster than Blue-Green's traffic flip, because there's no infrastructure change at all, just a config update propagated over an existing connection.
4. **Flag debt management**: The biggest long-term risk of this pattern is **flag proliferation** — old, stale flags left in code create combinatorial complexity and hidden bugs. Senior teams enforce flag expiry policies and regularly delete resolved flags (this is a real, well-known operational discipline, sometimes called "flag hygiene").
5. **Testing complexity**: With N flags, there are theoretically 2^N possible code paths in production. Senior engineers mitigate this via:
   - Automated tests that run against multiple flag combinations for critical flags.
   - Keeping flags **short-lived** (days/weeks, not years) — they should exist to de-risk a specific release, not become a permanent branching mechanism.

**Java Example — using a real feature flag SDK pattern (illustrative, LaunchDarkly-style API shape):**

```java
@Service
public class FeatureFlagAwareRecommendationService {

    private final FeatureFlagClient flagClient; // wraps the SDK
    private final RecommendationEngine legacyEngine;
    private final RecommendationEngine newEngine;

    public List<Product> getRecommendations(User user) {
        FlagContext context = FlagContext.builder()
                .userId(user.getId())
                .attribute("country", user.getCountry())
                .attribute("accountType", user.getAccountType())
                .build();

        boolean useNewEngine = flagClient.isEnabled("new-recommendation-engine", context, false);

        return useNewEngine ? newEngine.recommend(user.getId())
                             : legacyEngine.recommend(user.getId());
    }
}
```

```java
@Component
public class StaleFlagAuditor {

    // Runs periodically to flag toggles that have been at 100% (fully rolled out)
    // for over N days but never removed from code — a real operational practice.
    @Scheduled(cron = "0 0 9 * * MON")
    public void auditStaleFlags() {
        flagClient.getAllFlags().stream()
                .filter(flag -> flag.getRolloutPercentage() == 100)
                .filter(flag -> flag.getDaysAtFullRollout() > 30)
                .forEach(flag -> log.warn("Stale flag candidate for removal: {}", flag.getKey()));
    }
}
```

### Feature Flags Combined With Other Strategies (Senior Insight)
Feature Flags are often layered **on top of** Rolling/Blue-Green/Canary deployments, not used as a total replacement:
- **Deploy** the code via Rolling or Blue-Green (safe, infrastructure-level rollout).
- **Release** the feature via flag (safe, business-level rollout).
- This gives two independent, composable safety nets — a bad *deployment* is fixed by rollback; a bad *feature* is fixed by a flag flip, without touching infrastructure at all.

| Aspect | Detail |
|---|---|
| Downtime | No |
| Rollback | Instant — flip flag off, no redeploy or infra change needed |
| Complexity | Medium (flag platform + discipline to avoid flag debt) |
| Best for | Decoupling release timing from deployment, gradual feature rollout, instant kill switches |

---

## 8. Master Comparison Table

| Technique | Downtime | Rollback | Infra Cost | Primary Goal | Typical Tooling |
|---|---|---|---|---|---|
| **Recreate** | Yes | Easy | 1x | Simplicity, breaking changes | Kubernetes (`type: Recreate`) |
| **Rolling** | No | Moderate | ~1x–1.3x | Zero-downtime standard rollout | Kubernetes (`RollingUpdate`) |
| **Blue-Green** | No | Very Easy | 2x (temporary) | Instant rollback safety | AWS ALB, K8s Service swap, Istio |
| **Canary** | No | Easy | ~1x–1.2x | De-risking releases gradually | Istio, Argo Rollouts, Flagger |
| **A/B Testing** | No | Easy | ~1x | Business/UX experimentation | LaunchDarkly, Optimizely, GrowthBook |
| **Shadow (Mirroring)** | No | Not usually needed | ~2x (shadow capacity) | Validate new system against real traffic, risk-free | Istio mirroring, Diffy |
| **Feature Flag** | No | Instant | 1x | Decouple deploy from release | LaunchDarkly, Unleash, Flagsmith |

---

## 9. How to Choose the Right Strategy

A senior engineer typically reasons through these questions in order:

1. **Can the system tolerate any downtime?**
   - No → eliminate Recreate.
2. **Is this change risky/unproven (new algorithm, rewritten service, unpredictable performance)?**
   - Yes → strongly consider **Shadow Deployment** first, then **Canary** for the real rollout.
3. **Do you need the fastest possible rollback, regardless of infra cost?**
   - Yes → **Blue-Green** (infra-level) and/or **Feature Flags** (code-level) — these are often combined.
4. **Is the goal to measure user behavior/business impact rather than just "does it crash"?**
   - Yes → this isn't a deployment safety question at all — use **A/B Testing**.
5. **Do you want to separate "when code ships" from "when users see it"?**
   - Yes → **Feature Flags**, layered on top of whichever deployment mechanism (Rolling/Blue-Green) you already use.
6. **Is this a routine, low-risk change to a stateless service?**
   - Yes → plain **Rolling Deployment** is usually sufficient and is the most cost-efficient default.

**In real-world senior architecture, these are rarely mutually exclusive.** A mature deployment pipeline typically looks like:

```
Code merged → Rolling deployment to production (infra-safe rollout, feature flag OFF)
            → Shadow traffic validation (for high-risk services)
            → Canary release of the flag to 5% of users (release-safe rollout)
            → Gradual flag rollout to 100%
            → A/B test framework measures business impact post-rollout
            → Stale flag removed after 30 days at 100%
```

This layered approach is what allows large-scale systems (e.g., at companies like Google, Netflix, Meta) to ship changes dozens or hundreds of times per day with very low blast radius per change.
