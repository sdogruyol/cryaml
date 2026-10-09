# Deterministic benchmark inputs. Shared by both benchmark binaries so they
# parse byte-identical documents.
module BenchInputs
  SAMPLES = File.expand_path("../samples", __DIR__)

  # ~1 KB: a docker-compose / shard.yml style config.
  def self.small : String
    String.build do |io|
      io << "name: my-app\nversion: 1.4.2\n\nauthors:\n  - Jane Doe <jane@example.com>\n"
      io << "\ndependencies:\n"
      %w(kemal db pg redis).each_with_index do |dep, i|
        io << "  " << dep << ":\n    github: example/" << dep << "\n    version: \"~> " << i + 1 << ".0\"\n"
      end
      io << "\nservices:\n  web:\n    image: \"nginx:1.27\"\n    ports: [\"80:80\", \"443:443\"]\n"
      io << "    environment:\n      LOG_LEVEL: debug\n      WORKERS: 4\n      ENABLE_TLS: true\n"
      io << "    healthcheck:\n      test: [\"CMD\", \"curl\", \"-f\", \"http://localhost\"]\n      interval: 30s\n"
      io << "  db:\n    image: postgres:16\n    volumes:\n      - db-data:/var/lib/postgresql/data\n"
      io << "    command: >\n      postgres -c max_connections=200\n      -c shared_buffers=256MB\n"
      io << "volumes:\n  db-data: {}\n"
      io << "# deployment notes\nnotes: |\n  Rolling deploys only.\n  Keep at least two replicas.\n"
    end
  end

  # Kubernetes-style multi-document manifests, about *bytes* long.
  def self.manifests(bytes : Int32) : String
    String.build do |io|
      i = 0
      while io.bytesize < bytes
        io << "---\napiVersion: apps/v1\nkind: Deployment\nmetadata:\n  name: service-" << i << "\n"
        io << "  labels: &labels\n    app: service-" << i << "\n    tier: backend\n    team: \"platform\"\n"
        io << "spec:\n  replicas: " << (i % 5) + 1 << "\n  selector:\n    matchLabels: *labels\n"
        io << "  template:\n    metadata:\n      labels:\n        <<: *labels\n        version: v" << i % 3 << "\n"
        io << "    spec:\n      containers:\n        - name: app\n          image: registry.example.com/service-" << i << ":1." << i % 10 << ".0\n"
        io << "          args: [\"--port=8080\", \"--log-level=info\", '--name=svc #" << i << "']\n"
        io << "          env:\n            - name: DATABASE_URL\n              value: \"postgres://user:pass@db:5432/app_" << i << "\"\n"
        io << "            - name: TIMEOUT\n              value: \"30\"\n"
        io << "          resources:\n            limits: {cpu: 500m, memory: 128Mi}\n            requests: {cpu: 250m, memory: 64Mi}\n"
        io << "          readinessProbe:\n            httpGet:\n              path: /healthz\n              port: 8080\n            initialDelaySeconds: 5\n"
        io << "      annotations:\n        description: >-\n          Service number " << i << " handles requests\n          for the example platform.\n"
        i += 1
      end
    end
  end

  # Alternating block mappings and sequences, well below the 512 nesting
  # limit but deep enough to stress indentation handling.
  def self.deep(depth : Int32 = 200, repeat : Int32 = 20) : String
    String.build do |io|
      repeat.times do |r|
        io << "tree" << r << ":\n"
        indent = 2
        depth.times do |d|
          if d.even?
            io << " " * indent << "level" << d << ":\n"
            indent += 2
          else
            io << " " * indent << "- item" << d << ":\n"
            indent += 4
          end
        end
        io << " " * indent << "leaf\n"
      end
    end
  end

  # JSON-like flow collections, about *bytes* long.
  def self.flow(bytes : Int32) : String
    String.build do |io|
      io << "[\n"
      i = 0
      while io.bytesize < bytes
        io << "  {id: " << i << ", name: \"user-" << i << "\", active: " << i.even? << ", score: " << i * 1.5
        io << ", tags: [a, b, \"c d\", 'e'], geo: {lat: " << (i % 90) << ".5, lng: -" << (i % 180) << ".25}},\n"
        i += 1
      end
      io << "]\n"
    end
  end

  def self.all : Array({String, String})
    [
      {"small config (1 KB)", small},
      {"helm values (50 KB, real)", File.read(File.join(SAMPLES, "helm-nginx-values.yaml"))},
      {"manifests (100 KB)", manifests(100_000)},
      {"manifests (1 MB)", manifests(1_000_000)},
      {"deep nesting (300 levels)", deep},
      {"flow heavy (200 KB)", flow(200_000)},
    ]
  end
end
