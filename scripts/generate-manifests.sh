#!/bin/bash
# =============================================================================
# SCRIPT: generate-manifests.sh
# DESCRIÇÃO: Gera automaticamente toda a estrutura de manifests YAML para
#            deploy de Cloudflare Tunnel em cluster k3s com FreeDomain.
#
# USO: ./generate-manifests.sh <nome-do-projeto> <dominio> <tunnel-name>
# EXEMPLO: ./generate-manifests.sh meu-lab app.meudominio.dpdns.org k3s-homelab
#
# REQUISITOS:
#   - bash 4.0+
#   - Permissão de escrita no diretório atual
#
# AUTOR: Alexsandro J Silva
# DATA: 2026
# =============================================================================

set -euo pipefail  # Sai em erro, variáveis não declaradas, falha em pipe

# =============================================================================
# CONFIGURAÇÕES E VALIDAÇÕES INICIAIS
# =============================================================================

# Cores para output (melhora legibilidade no terminal)
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly NC='\033[0m' # No Color

# Função para logging com cores
log_info()    { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[OK]${NC} $1"; }
log_warn()    { echo -e "${YELLOW}[AVISO]${NC} $1"; }
log_error()   { echo -e "${RED}[ERRO]${NC} $1" >&2; }

# Validação de argumentos
if [[ $# -ne 3 ]]; then
    echo "Uso: $0 <nome-do-projeto> <dominio-principal> <nome-do-tunnel>"
    echo "Exemplo: $0 meu-lab app.meudominio.dpdns.org k3s-homelab"
    exit 1
fi

# Captura e sanitiza argumentos
readonly PROJECT_NAME="${1//[^a-zA-Z0-9-]/-}"      # kebab-case forçado
readonly MAIN_DOMAIN="$2"                           # ex: app.meudominio.dpdns.org
readonly TUNNEL_NAME="${3//[^a-zA-Z0-9-]/-}"        # nome do túnel na Cloudflare
readonly BASE_DOMAIN="${MAIN_DOMAIN#*.}"            # extrai: meudominio.dpdns.org
readonly NAMESPACE="infrastructure"
readonly TIMESTAMP=$(date +%Y%m%d_%H%M%S)

# Diretório raiz do projeto
readonly PROJECT_DIR="${PROJECT_NAME}-k3s-cloudflared"

# =============================================================================
# FUNÇÕES AUXILIARES
# =============================================================================

# Cria diretório se não existir
ensure_dir() {
    local dir="$1"
    if [[ ! -d "$dir" ]]; then
        mkdir -p "$dir"
        log_info "Criado diretório: $dir"
    fi
}

# Escreve arquivo com header padrão
write_file_header() {
    local file="$1"
    local description="$2"
    cat << EOF > "$file"
# =============================================================================
# ARQUIVO: $(basename "$file")
# PROJETO: ${PROJECT_NAME}
# DESCRIÇÃO: ${description}
# DOMÍNIO: ${MAIN_DOMAIN}
# TÚNEL: ${TUNNEL_NAME}
# GERADO EM: ${TIMESTAMP}
# =============================================================================
# ⚠️  ESTE ARQUIVO FOI GERADO AUTOMATICAMENTE.
#    Alterações manuais podem ser sobrescritas ao regerar.
#    Para personalizar, edite após a geração ou modifique este script.
# =============================================================================

EOF
}

# =============================================================================
# GERAÇÃO DOS ARQUIVOS YAML
# =============================================================================

generate_namespace() {
    local file="$1"
    write_file_header "$file" "Namespace para isolamento de recursos de infraestrutura"
    
    cat << 'EOF' >> "$file"
# ------------------------------------------------------------------------------
# RECURSO: Namespace
# OBJETIVO: Isolar recursos de infraestrutura (cloudflared, monitoring, etc.)
#           dos aplicativos de negócio, facilitando RBAC, quotas e organização.
# ------------------------------------------------------------------------------
apiVersion: v1
kind: Namespace
metadata:
  name: infrastructure
  labels:
    name: infrastructure
    managed-by: kustomize  # Indica que é gerenciado por GitOps (opcional)
    cloudflared-enabled: "true"
EOF
    log_success "Gerado: $file"
}

generate_secret_template() {
    local file="$1"
    write_file_header "$file" "Template de Secret para token do Cloudflare Tunnel"
    
    cat << EOF >> "$file"
# ------------------------------------------------------------------------------
# RECURSO: Secret (Opaque)
# OBJETIVO: Armazenar com segurança o token de autenticação do túnel Cloudflare.
#
# ⚠️  IMPORTANTE:
#   1. Este arquivo é um TEMPLATE. O token REAL deve ser injetado de forma segura:
#      a) Via variável de ambiente no deploy: CLOUDFLARE_TUNNEL_TOKEN
#      b) Via SealedSecrets (recomendado para GitOps)
#      c) Via External Secrets Operator + Vault/AWS Secrets Manager
#
#   2. NUNCA commitar este arquivo com token real no Git.
#      Use .gitignore e .env.example para controle.
#
#   3. Formato do token: JWT com tunnel ID + secret key + permissões.
#      Exemplo: eyJhIjoiNWFiNGU5Z... (base64url encoded)
# ------------------------------------------------------------------------------
apiVersion: v1
kind: Secret
metadata:
  name: cloudflared-credentials
  namespace: infrastructure
  labels:
    app: cloudflared
    managed-by: generate-manifests.sh
type: Opaque
stringData:
  # ← SUBSTITUA ESTE VALOR PELO TOKEN REAL ANTES DO DEPLOY
  # Para obter o token:
  #   1. Acesse https://one.dash.cloudflare.com/
  #   2. Zero Trust > Networks > Tunnels > Seu Túnel > Configure
  #   3. Copie o token da seção "Install and run a connector"
  token: "REPLACE_ME_WITH_CLOUDFLARE_TUNNEL_TOKEN"
  
  # Metadados úteis para auditoria (opcionais)
  metadata.json: |
    {
      "tunnel_name": "${TUNNEL_NAME}",
      "domain": "${MAIN_DOMAIN}",
      "generated_at": "${TIMESTAMP}",
      "project": "${PROJECT_NAME}"
    }
EOF
    log_success "Gerado: $file"
}

generate_configmap() {
    local file="$1"
    write_file_header "$file" "ConfigMap com regras de ingress e configurações do cloudflared"
    
    cat << EOF >> "$file"
# ------------------------------------------------------------------------------
# RECURSO: ConfigMap
# OBJETIVO: Definir configuração NÃO sensível do cloudflared:
#   - Nome do túnel e arquivo de credenciais
#   - Regras de ingress (roteamento hostname → serviço interno)
#   - Configurações de log, métricas e comportamento
#
# VANTAGEM: Atualizações no ConfigMap recarregam o cloudflared dinamicamente
#           (~15-30s) SEM necessidade de restart do pod.
# ------------------------------------------------------------------------------
apiVersion: v1
kind: ConfigMap
metadata:
  name: cloudflared-config
  namespace: infrastructure
  labels:
    app: cloudflared
    managed-by: generate-manifests.sh
data:
  config.yaml: |
    # ================================================================
    # CONFIGURAÇÕES GERAIS DO TÚNEL
    # ================================================================
    
    # Nome do túnel (DEVE coincidir com o criado no dashboard Cloudflare)
    tunnel: ${TUNNEL_NAME}
    
    # Caminho para o arquivo de credenciais (montado via Secret)
    credentials-file: /etc/cloudflared/creds/credentials.json
    
    # ================================================================
    # MONITORAMENTO, LOGS E COMPORTAMENTO
    # ================================================================
    
    # Expõe métricas Prometheus e health checks na porta 2000
    # Acessível apenas dentro do cluster ou via kubectl port-forward
    metrics: 0.0.0.0:2000
    
    # Desabilita autoupdate do binário cloudflared
    # Motivo: Em Kubernetes, VOCÊ controla a versão via 'image:' no Deployment
    no-autoupdate: true
    
    # Nível de log: debug | info | warn | error
    # Use 'debug' apenas para troubleshooting; 'info' para produção
    loglevel: info
    
    # Tempo de espera para conexões upstream (ajuste conforme necessidade)
    connect-timeout: 30s
    
    # ================================================================
    # REGRAS DE INGRESS (Roteamento de tráfego)
    # Formato: hostname + path → serviço interno do Kubernetes
    # Avaliação: SEQUENCIAL (primeiro match vence). Catch-all deve ser último.
    # ================================================================
    ingress:
      # ----------------------------------------------------------------
      # REGRA 1: Aplicação principal
      # ----------------------------------------------------------------
      - hostname: "${MAIN_DOMAIN}"
        service: http://exemplo-app-svc:80
        path: /
        # Opções avançadas (descomente se necessário):
        # originRequest:
        #   noTLSVerify: false          # Validar certificado do backend
        #   connectTimeout: 10s         # Timeout específico para esta rota
        #   httpHostHeader: "\${HOST}"  # Preserva header Host original
      
      # ----------------------------------------------------------------
      # REGRA 2: Health check dedicado (monitoramento externo)
      # ----------------------------------------------------------------
      - hostname: "health.${BASE_DOMAIN}"
        service: http_status:200
        # ↑ Responde sempre HTTP 200, sem depender da aplicação.
        #   Útil para uptime monitors (UptimeRobot, Healthchecks.io, etc.)
      
      # ----------------------------------------------------------------
      # REGRA 3: API (exemplo de sub-rota com path prefix)
      # ----------------------------------------------------------------
      # - hostname: "${MAIN_DOMAIN}"
      #   service: http://api-svc:8080
      #   path: /api
      #   # ↑ Roteia apenas requisições para /api/* para o serviço de API
      
      # ----------------------------------------------------------------
      # REGRA 4: Catch-all (SEGURANÇA - deve ser a ÚLTIMA regra)
      # ----------------------------------------------------------------
      - service: http_status:404
        # ↑ Retorna 404 para qualquer hostname/path não mapeado.
        #   Previne exposição acidental de serviços internos.
EOF
    log_success "Gerado: $file"
}

generate_deployment() {
    local file="$1"
    write_file_header "$file" "Deployment do cloudflared com health checks e recursos"
    
    cat << 'EOF' >> "$file"
# ------------------------------------------------------------------------------
# RECURSO: Deployment (apps/v1)
# OBJETIVO: Orquestrar pods do cloudflared com:
#   - Alta disponibilidade (múltiplas réplicas)
#   - Health checks (liveness/readiness probes)
#   - Limites de recursos (evita "noisy neighbor")
#   - Estratégia de update sem downtime (RollingUpdate)
#
# COMPORTAMENTO: 
#   - Se um pod falhar, Kubernetes reinicia automaticamente (self-healing)
#   - Atualizações de imagem/config são aplicadas gradualmente (zero downtime)
# ------------------------------------------------------------------------------
apiVersion: apps/v1
kind: Deployment
metadata:
  name: cloudflared
  namespace: infrastructure
  labels:
    app: cloudflared
    managed-by: generate-manifests.sh
spec:
  # Estratégia de rollout (padrão: RollingUpdate)
  strategy:
    type: RollingUpdate
    rollingUpdate:
      maxSurge: 1           # Pode criar 1 pod extra durante update
      maxUnavailable: 0     # Garante que SEMPRE haja pelo menos 1 pod ativo
  
  # Número de réplicas para alta disponibilidade
  # Ajuste conforme criticidade: 1 para dev, 2+ para produção
  replicas: 2
  
  # Selector: identifica quais pods este Deployment gerencia
  selector:
    matchLabels:
      app: cloudflared
  
  # Template: modelo para criação de novos pods
  template:
    metadata:
      labels:
        app: cloudflared
        # Labels adicionais para monitoramento/organização
        component: tunnel
        environment: production  # Altere para 'staging'/'dev' conforme ambiente
    spec:
      # Segurança: evita que pods sejam escalonados em nós inadequados
      affinity:
        podAntiAffinity:
          preferredDuringSchedulingIgnoredDuringExecution:
          - weight: 100
            podAffinityTerm:
              labelSelector:
                matchExpressions:
                - key: app
                  operator: In
                  values:
                  - cloudflared
              topologyKey: kubernetes.io/hostname
      # ↑ Tenta distribuir réplicas em nós diferentes (melhor resiliência)
      
      containers:
        - name: cloudflared
          # Imagem oficial da Cloudflare (use tag específica em produção)
          image: cloudflare/cloudflared:latest
          
          # Política de pull de imagem (Always garante versão mais recente)
          imagePullPolicy: IfNotPresent
          
          # Argumentos de inicialização do binário cloudflared
          args:
            - tunnel
            - --config
            - /etc/cloudflared/config/config.yaml
            - run
          
          # Variáveis de ambiente
          env:
            # Token de autenticação (injetado via Secret)
            - name: TUNNEL_TOKEN
              valueFrom:
                secretKeyRef:
                  name: cloudflared-credentials
                  key: token
            # Variáveis para debugging/monitoramento (opcionais)
            - name: CLOUDFLARED_METRICS
              value: "0.0.0.0:2000"
          
          # Portas expostas pelo container (apenas para comunicação interna)
          ports:
            - containerPort: 2000
              name: metrics
              protocol: TCP
          
          # Health Checks: Kubernetes monitora saúde do container
          
          # Liveness Probe: "O container está travado? Se sim, reinicia."
          livenessProbe:
            httpGet:
              path: /ready
              port: metrics
              scheme: HTTP
            initialDelaySeconds: 15   # Aguarda 15s após start para primeira checagem
            periodSeconds: 10         # Verifica a cada 10 segundos
            timeoutSeconds: 5         # Timeout por tentativa
            successThreshold: 1       # 1 sucesso = considerado saudável
            failureThreshold: 3       # 3 falhas consecutivas = reinicia container
          
          # Readiness Probe: "O container está pronto para tráfego?"
          readinessProbe:
            httpGet:
              path: /ready
              port: metrics
              scheme: HTTP
            initialDelaySeconds: 5    # Começa a verificar mais cedo que liveness
            periodSeconds: 5
            timeoutSeconds: 3
            successThreshold: 1
            failureThreshold: 3
          # ↑ Enquanto readiness falha: pod não recebe tráfego de Services
          
          # Recursos: limites de CPU/memória (evita consumo excessivo)
          resources:
            requests:                 # Recursos GARANTIDOS (reserva no nó)
              memory: "64Mi"
              cpu: "50m"              # 50 milicpus = 0.05 núcleo
            limits:                   # Recursos MÁXIMOS permitidos
              memory: "128Mi"
              cpu: "100m"
          
          # Security Context: boas práticas de segurança para container
          securityContext:
            allowPrivilegeEscalation: false
            readOnlyRootFilesystem: true
            runAsNonRoot: true
            runAsUser: 10001          # Usuário não-privilegiado (padrão da imagem)
            capabilities:
              drop:
                - ALL                 # Remove todas as capabilities Linux
          
          # Volume Mounts: conecta volumes externos ao filesystem do container
          volumeMounts:
            - name: config-volume
              mountPath: /etc/cloudflared/config
              readOnly: true
            - name: creds-volume
              mountPath: /etc/cloudflared/creds
              readOnly: true
            # Volume temporário para logs (evita escrita em rootfs)
            - name: tmp-volume
              mountPath: /tmp
              readOnly: false
      
      # Volumes: define fontes dos dados montados nos volumeMounts
      volumes:
        - name: config-volume
          configMap:
            name: cloudflared-config
            defaultMode: 0444         # Permissão: apenas leitura (r--r--r--)
            items:
              - key: config.yaml
                path: config.yaml
        - name: creds-volume
          secret:
            secretName: cloudflared-credentials
            defaultMode: 0400         # Permissão: apenas owner lê (r--------)
            items:
              - key: token
                path: credentials.json
        - name: tmp-volume
          emptyDir: {}                # Volume efêmero em memória/tmpfs
EOF
    log_success "Gerado: $file"
}

generate_example_app() {
    local file="$1"
    write_file_header "$file" "Template de aplicação exemplo (Service + Deployment)"
    
    cat << EOF >> "$file"
# ------------------------------------------------------------------------------
# RECURSO: Service + Deployment (template de aplicação)
# OBJETIVO: Exemplo de como estruturar SUA aplicação para ser acessível
#           via Cloudflare Tunnel.
#
# INSTRUÇÕES:
#   1. Copie este arquivo para apps/<seu-app>/manifests.yaml
#   2. Substitua 'exemplo-app' pelo nome da sua aplicação
#   3. Ajuste imagem, portas, recursos e variáveis de ambiente
#   4. Adicione uma regra correspondente no ConfigMap do cloudflared
# ------------------------------------------------------------------------------

# ================================================================
# SERVICE: Endpoint interno estável para a aplicação
# ================================================================
apiVersion: v1
kind: Service
metadata:
  name: exemplo-app-svc
  namespace: default
  labels:
    app: exemplo-app
spec:
  type: ClusterIP                 # ← CRÍTICO: NUNCA use NodePort/LoadBalancer aqui
  selector:
    app: exemplo-app              # Seleciona pods com esta label
  ports:
    - name: http
      port: 80                    # Porta EXPOSTA pelo Service (dentro do cluster)
      targetPort: 3000            # Porta do CONTAINER (onde sua app escuta)
      protocol: TCP
  # sessionAffinity: None         # Opcional: ClientIP para sticky sessions

---
# ================================================================
# DEPLOYMENT: Orquestração dos pods da aplicação
# ================================================================
apiVersion: apps/v1
kind: Deployment
metadata:
  name: exemplo-app
  namespace: default
  labels:
    app: exemplo-app
spec:
  replicas: 1                     # Ajuste conforme necessidade de escala
  selector:
    matchLabels:
      app: exemplo-app
  template:
    metadata:
      labels:
        app: exemplo-app
    spec:
      containers:
        - name: app
          # Substitua pela sua imagem real
          image: nginx:alpine     # Exemplo: troque por sua-app:v1.2.3
          imagePullPolicy: IfNotPresent
          
          ports:
            - containerPort: 3000 # Deve bater com targetPort do Service
              name: http
              protocol: TCP
          
          # Health checks da SUA aplicação (ajuste conforme sua app)
          livenessProbe:
            httpGet:
              path: /health       # Endpoint que sua app deve implementar
              port: http
            initialDelaySeconds: 10
            periodSeconds: 10
          readinessProbe:
            httpGet:
              path: /ready
              port: http
            initialDelaySeconds: 5
            periodSeconds: 5
          
          # Recursos: ajuste conforme perfil da sua aplicação
          resources:
            requests:
              memory: "128Mi"
              cpu: "100m"
            limits:
              memory: "256Mi"
              cpu: "200m"
          
          # Variáveis de ambiente (exemplo)
          env:
            - name: NODE_ENV
              value: "production"
            # - name: DATABASE_URL
            #   valueFrom:
            #     secretKeyRef:
            #       name: app-secrets
            #       key: database-url
          
          # Security context (boas práticas)
          securityContext:
            allowPrivilegeEscalation: false
            runAsNonRoot: true
            runAsUser: 1000
EOF
    log_success "Gerado: $file"
}

generate_kustomization() {
    local file="$1"
    write_file_header "$file" "Kustomization para GitOps (Flux/ArgoCD)"
    
    cat << 'EOF' >> "$file"
# ------------------------------------------------------------------------------
# RECURSO: Kustomization (kustomize.config.k8s.io/v1beta1)
# OBJETIVO: Permitir gerenciamento declarativo via GitOps tools (Flux, ArgoCD).
#
# USO COM FLUX:
#   apiVersion: kustomize.toolkit.fluxcd.io/v1beta2
#   kind: Kustomization
#   metadata:
#     name: cloudflared
#     namespace: flux-system
#   spec:
#     path: ./infrastructure/cloudflared
#     prune: true
#     sourceRef:
#       kind: GitRepository
#       name: cluster-configs
#
# USO COM ARGOCD:
#   Aponte o Application para este diretório com 'kustomize' como generator.
# ------------------------------------------------------------------------------
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization

# Recursos a serem aplicados (ordem respeitada pelo kustomize)
resources:
  - 01-namespace.yaml
  - 02-secret-tunnel.yaml
  - 03-configmap-cloudflared.yaml
  - 04-deployment-cloudflared.yaml

# Labels comuns a todos os recursos (opcional, para organização)
commonLabels:
  managed-by: kustomize
  project: cloudflared-tunnel

# Namespace padrão para todos os recursos (redundante, mas explícito)
namespace: infrastructure

# Patches estratégicos (exemplo: ajustar réplicas por ambiente)
# patches:
#   - target:
#       kind: Deployment
#       name: cloudflared
#     patch: |-
#       - op: replace
#         path: /spec/replicas
#         value: 3  # Produção: mais réplicas
EOF
    log_success "Gerado: $file"
}

# =============================================================================
# SCRIPTS AUXILIARES DE DEPLOY E VALIDAÇÃO
# =============================================================================

generate_deploy_script() {
    local file="$1"
    write_file_header "$file" "Script de deploy automatizado com validações"
    
    cat << 'EOF' >> "$file"
#!/bin/bash
# =============================================================================
# SCRIPT: deploy.sh
# DESCRIÇÃO: Aplica manifests do Cloudflare Tunnel no cluster k3s com validações
# =============================================================================

set -euo pipefail

# Configurações
readonly NAMESPACE="infrastructure"
readonly TIMEOUT="120s"

# Cores
readonly GREEN='\033[0;32m'
readonly RED='\033[0;31m'
readonly NC='\033[0m'

log() { echo -e "${GREEN}[DEPLOY]${NC} $1"; }
error() { echo -e "${RED}[ERRO]${NC} $1" >&2; }

# Verifica pré-requisitos
check_prerequisites() {
    log "Verificando pré-requisitos..."
    
    command -v kubectl >/dev/null 2>&1 || { error "kubectl não encontrado"; exit 1; }
    
    # Verifica conexão com cluster
    if ! kubectl cluster-info >/dev/null 2>&1; then
        error "Não foi possível conectar ao cluster Kubernetes"
        exit 1
    fi
    log "✓ Cluster acessível"
    
    # Verifica se token foi injetado (não aceita placeholder)
    if grep -q "REPLACE_ME_WITH_CLOUDFLARE_TUNNEL_TOKEN" infrastructure/cloudflared/02-secret-tunnel.yaml 2>/dev/null; then
        error "Token do Cloudflare não configurado!"
        echo "Edite infrastructure/cloudflared/02-secret-tunnel.yaml e substitua o placeholder"
        exit 1
    fi
    log "✓ Token configurado"
}

# Aplica manifests em ordem
apply_manifests() {
    local dir="$1"
    log "Aplicando manifests de: $dir"
    
    # Aplica YAMLs em ordem alfabética (garante dependências)
    for manifest in $(ls "$dir"/*.yaml 2>/dev/null | sort); do
        log "→ $(basename "$manifest")"
        kubectl apply -f "$manifest"
    done
}

# Aguarda recursos estarem ready
wait_ready() {
    log "Aguardando recursos estarem prontos..."
    
    # Aguarda Deployment do cloudflared
    if ! kubectl wait --for=condition=available \
        deployment/cloudflared -n "$NAMESPACE" --timeout="$TIMEOUT" 2>/dev/null; then
        error "Timeout aguardando cloudflared ficar disponível"
        kubectl rollout status deployment/cloudflared -n "$NAMESPACE" || true
        return 1
    fi
    log "✓ cloudflared pronto"
    
    # Verifica logs iniciais para erros de conexão
    sleep 5
    if kubectl logs -l app=cloudflared -n "$NAMESPACE" --tail=20 | grep -qi "error\|fail"; then
        log_warn "Possíveis erros nos logs do cloudflared. Verifique com:"
        echo "  kubectl logs -l app=cloudflared -n $NAMESPACE -f"
    fi
}

# Main
main() {
    log "Iniciando deploy do Cloudflare Tunnel..."
    
    check_prerequisites
    apply_manifests "infrastructure/cloudflared"
    wait_ready
    
    log "✅ Deploy concluído!"
    echo ""
    echo "Próximos passos:"
    echo "  1. Configure DNS no FreeDomain/Cloudflare apontando para o túnel"
    echo "  2. Acesse https://${MAIN_DOMAIN:-seu-dominio}"
    echo "  3. Monitore logs: kubectl logs -l app=cloudflared -n $NAMESPACE -f"
    echo "  4. Teste health: curl https://health.${BASE_DOMAIN:-seu-dominio}"
}

main "$@"
EOF
    chmod +x "$file"
    log_success "Gerado: $file (com permissão de execução)"
}

generate_readme() {
    local file="$1"
    write_file_header "$file" "Documentação do projeto"
    
    cat << EOF >> "$file"
# ${PROJECT_NAME} - k3s + Cloudflare Tunnel + FreeDomain

> Deploy automatizado de serviços no k3s expostos via Cloudflare Tunnel, usando domínio gratuito do FreeDomain.

## 📋 Pré-requisitos

- Cluster k3s funcionando e \`kubectl\` configurado
- Conta na [Cloudflare Zero Trust](https://one.dash.cloudflare.com/)
- Domínio registrado no [FreeDomain](https://domain.digitalplat.org/) apontando para nameservers da Cloudflare

## 🚀 Deploy Rápido

\`\`\`bash
# 1. Gere os manifests (se ainda não fez)
./scripts/generate-manifests.sh ${PROJECT_NAME} ${MAIN_DOMAIN} ${TUNNEL_NAME}

# 2. Edite o secret com seu token real
#    Obtenha o token em: Cloudflare Zero Trust > Networks > Tunnels > Configure
nano ${PROJECT_DIR}/infrastructure/cloudflared/02-secret-tunnel.yaml

# 3. Execute o deploy
./scripts/deploy.sh
\`\`\`

## 📁 Estrutura de Arquivos

\`\`\`
${PROJECT_DIR}/
├── infrastructure/
│   └── cloudflared/
│       ├── 01-namespace.yaml          # Namespace 'infrastructure'
│       ├── 02-secret-tunnel.yaml      # Token do túnel (EDITAR ANTES DO DEPLOY)
│       ├── 03-configmap-cloudflared.yaml # Regras de ingress e config
│       ├── 04-deployment-cloudflared.yaml # Deployment do cloudflared
│       └── kustomization.yaml         # Para GitOps (Flux/ArgoCD)
├── scripts/
│   ├── generate-manifests.sh          # Este script (gera toda a estrutura)
│   └── deploy.sh                      # Script de deploy com validações
└── docs/
    └── README.md                      # Este arquivo
\`\`\`

## 🔧 Personalizando para Sua Aplicação

1. Crie seu manifesto de app em \`infrastructure/apps/seu-app/\`
2. Adicione regra de ingress no \`03-configmap-cloudflared.yaml\`:
   \`\`\`yaml
   ingress:
     - hostname: "${MAIN_DOMAIN}"
       service: http://seu-app-svc:80
       path: /
   \`\`\`
3. Aplique: \`kubectl apply -f infrastructure/apps/seu-app/\`

## 🔍 Debug e Monitoramento

\`\`\`bash
# Ver status dos pods
kubectl get pods -n infrastructure -l app=cloudflared

# Logs em tempo real
kubectl logs -l app=cloudflared -n infrastructure -f

# Testar health check interno
kubectl port-forward -n infrastructure deploy/cloudflared 2000:2000 &
curl http://localhost:2000/ready

# Verificar métricas Prometheus
curl http://localhost:2000/metrics
\`\`\`

## 🔐 Segurança

- ✅ Token armazenado em Secret (não em plain text)
- ✅ Container roda como usuário não-root
- ✅ Root filesystem em modo leitura-only
- ✅ Capabilities Linux removidas
- ✅ Sem portas abertas no firewall (túnel outbound)

## 🔄 Atualizações

### Atualizar regras de ingress (sem downtime):
\`\`\`bash
# Edite 03-configmap-cloudflared.yaml
kubectl apply -f infrastructure/cloudflared/03-configmap-cloudflared.yaml
# cloudflared recarrega config automaticamente em ~30s
\`\`\`

### Atualizar versão do cloudflared:
\`\`\`bash
# Edite 04-deployment-cloudflared.yaml: image: cloudflare/cloudflared:v2024.x.x
kubectl apply -f infrastructure/cloudflared/04-deployment-cloudflared.yaml
# Rollout automático com zero downtime
\`\`\`

## 🗑️ Remoção (Uninstall)

\`\`\`bash
kubectl delete -f infrastructure/cloudflared/
# Ou, para remover tudo do namespace:
kubectl delete namespace infrastructure
\`\`\`

## 📚 Referências

- [Cloudflare Tunnel Docs](https://developers.cloudflare.com/cloudflare-one/connections/connect-apps/)
- [FreeDomain](https://github.com/DigitalPlatDev/FreeDomain)
- [k3s Documentation](https://docs.k3s.io/)
- [Kubernetes Secrets Best Practices](https://kubernetes.io/docs/concepts/configuration/secret/)

---
*Gerado automaticamente em ${TIMESTAMP} por generate-manifests.sh*
EOF
    log_success "Gerado: $file"
}

generate_gitignore() {
    local file="$1"
    cat << 'EOF' > "$file"
# =============================================================================
# .gitignore - k3s-cloudflared-deploy
# =============================================================================

# Secrets com dados sensíveis (NUNCA commitar)
**/*secret*.yaml
!infrastructure/cloudflared/02-secret-tunnel.yaml  # Mantém template, mas...

# Arquivos de ambiente local
.env
.env.local
*.env

# Tokens e credenciais
*token*
*credentials*.json
*.key
*.pem

# Logs e temporários
*.log
tmp/
temp/
*.tmp

# IDE e editores
.vscode/
.idea/
*.swp
*.swo
*~

# Kubernetes temporários
*.yaml~
*.yml~

# Scripts gerados localmente (se houver overrides)
scripts/local-*

# Documentação gerada
docs/generated-*
EOF
    log_success "Gerado: $file"
}

generate_env_example() {
    local file="$1"
    cat << EOF > "$file"
# =============================================================================
# .env.example - Variáveis de ambiente template
# Copie para .env e preencha os valores (NÃO commitar .env)
# =============================================================================

# Token do Cloudflare Tunnel (obrigatório)
# Obtenha em: Cloudflare Zero Trust > Networks > Tunnels > Configure
CLOUDFLARE_TUNNEL_TOKEN=eyJhIjoi...

# Configurações do projeto (opcional, para scripts)
PROJECT_NAME=${PROJECT_NAME}
TUNNEL_NAME=${TUNNEL_NAME}
MAIN_DOMAIN=${MAIN_DOMAIN}
NAMESPACE=infrastructure

# Configurações de deploy (opcional)
KUBECONFIG=~/.kube/config
DRY_RUN=false
EOF
    log_success "Gerado: $file"
}

# =============================================================================
# FUNÇÃO PRINCIPAL: ORQUESTRA A GERAÇÃO DE TODOS OS ARQUIVOS
# =============================================================================

main() {
    echo -e "${BLUE}╔════════════════════════════════════════════════════════╗${NC}"
    echo -e "${BLUE}║  Gerando estrutura para: ${PROJECT_NAME}${NC}"
    echo -e "${BLUE}║  Domínio: ${MAIN_DOMAIN}${NC}"
    echo -e "${BLUE}║  Túnel: ${TUNNEL_NAME}${NC}"
    echo -e "${BLUE}╚════════════════════════════════════════════════════════╝${NC}"
    echo ""
    
    # Cria estrutura de diretórios
    log_info "Criando estrutura de diretórios..."
    ensure_dir "$PROJECT_DIR"
    ensure_dir "$PROJECT_DIR/infrastructure/cloudflared"
    ensure_dir "$PROJECT_DIR/infrastructure/apps/exemplo-app"
    ensure_dir "$PROJECT_DIR/scripts"
    ensure_dir "$PROJECT_DIR/docs"
    
    # Gera manifests YAML
    log_info "Gerando manifests YAML..."
    generate_namespace "$PROJECT_DIR/infrastructure/cloudflared/01-namespace.yaml"
    generate_secret_template "$PROJECT_DIR/infrastructure/cloudflared/02-secret-tunnel.yaml"
    generate_configmap "$PROJECT_DIR/infrastructure/cloudflared/03-configmap-cloudflared.yaml"
    generate_deployment "$PROJECT_DIR/infrastructure/cloudflared/04-deployment-cloudflared.yaml"
    generate_example_app "$PROJECT_DIR/infrastructure/apps/exemplo-app/manifests.yaml"
    generate_kustomization "$PROJECT_DIR/infrastructure/cloudflared/kustomization.yaml"
    
    # Gera scripts auxiliares
    log_info "Gerando scripts auxiliares..."
    generate_deploy_script "$PROJECT_DIR/scripts/deploy.sh"
    
    # Gera documentação e configuração
    log_info "Gerando documentação e configuração..."
    generate_readme "$PROJECT_DIR/docs/README.md"
    generate_gitignore "$PROJECT_DIR/.gitignore"
    generate_env_example "$PROJECT_DIR/.env.example"
    
    # Resumo final
    echo ""
    log_success "✅ Estrutura gerada com sucesso em: ./${PROJECT_DIR}/"
    echo ""
    echo -e "${YELLOW}⚠️  PRÓXIMOS PASSOS OBRIGATÓRIOS:${NC}"
    echo "   1. Edite: ${PROJECT_DIR}/infrastructure/cloudflared/02-secret-tunnel.yaml"
    echo "      → Substitua 'REPLACE_ME_WITH_CLOUDFLARE_TUNNEL_TOKEN' pelo token real"
    echo "   2. Revise as regras de ingress em: 03-configmap-cloudflared.yaml"
    echo "   3. Execute o deploy: cd ${PROJECT_DIR} && ./scripts/deploy.sh"
    echo ""
    echo -e "${BLUE}📖 Consulte a documentação: ${PROJECT_DIR}/docs/README.md${NC}"
}

# Executa função principal
main "$@"
EOF
    log_success "Gerado: $file"
}

generate_makefile() {
    local file="$1"
    write_file_header "$file" "Makefile com comandos shortcuts para desenvolvimento"
    
    cat << 'EOF' >> "$file"
# =============================================================================
# Makefile - Comandos shortcuts para gerenciamento do projeto
# =============================================================================

.PHONY: help deploy validate logs clean apply generate

# Variáveis configuráveis (podem ser sobrescritas via CLI)
NAMESPACE ?= infrastructure
PROJECT ?= $(shell basename $(CURDIR))
DOMAIN ?= app.example.dpdns.org

# Exibe ajuda
help:
	@echo "Comandos disponíveis para $(PROJECT):"
	@echo ""
	@echo "  make generate   - Gera estrutura de arquivos (primeira vez)"
	@echo "  make validate   - Valida manifests com kubeconform"
	@echo "  make apply      - Aplica todos os manifests (kubectl apply)"
	@echo "  make deploy     - Valida + aplica (deploy completo)"
	@echo "  make logs       - Tail dos logs do cloudflared"
	@echo "  make status     - Status dos recursos no namespace"
	@echo "  make clean      - Remove recursos do namespace (cuidado!)"
	@echo ""
	@echo "Exemplos:"
	@echo "  make generate PROJECT=meu-app DOMAIN=api.meudominio.dpdns.org"
	@echo "  make deploy NAMESPACE=prod"

# Gera estrutura (chama o script principal)
generate:
	@echo "🔄 Gerando estrutura para $(PROJECT)..."
	@./scripts/generate-manifests.sh $(PROJECT) $(DOMAIN) cloudflared

# Valida manifests (requer kubeconform: https://github.com/yannh/kubeconform)
validate:
	@echo "🔍 Validando manifests..."
	@command -v kubeconform >/dev/null 2>&1 || { \
		echo "⚠️  kubeconform não encontrado. Instalando via go..."; \
		go install github.com/yannh/kubeconform/cmd/kubeconform@latest; \
	}
	@find infrastructure -name "*.yaml" -exec kubeconform -strict {} \;
	@echo "✅ Validação concluída"

# Aplica manifests em ordem
apply:
	@echo "🚀 Aplicando manifests..."
	@kubectl apply -f infrastructure/cloudflared/01-namespace.yaml
	@kubectl apply -f infrastructure/cloudflared/02-secret-tunnel.yaml
	@kubectl apply -f infrastructure/cloudflared/03-configmap-cloudflared.yaml
	@kubectl apply -f infrastructure/cloudflared/04-deployment-cloudflared.yaml
	@echo "✅ Apply concluído"

# Deploy completo: valida + aplica
deploy: validate apply
	@echo "⏳ Aguardando recursos ficarem ready..."
	@kubectl wait --for=condition=ready pod -l app=cloudflared -n $(NAMESPACE) --timeout=120s
	@echo "✅ Deploy concluído! Acesse: https://$(DOMAIN)"

# Logs em tempo real
logs:
	@kubectl logs -l app=cloudflared -n $(NAMESPACE) -f

# Status dos recursos
status:
	@echo "📊 Status em namespace $(NAMESPACE):"
	@kubectl get all -n $(NAMESPACE) -l app=cloudflared
	@echo ""
	@echo "🔗 Túneis registrados:"
	@kubectl exec -n $(NAMESPACE) -l app=cloudflared -- cloudflared tunnel list --credentials-file /etc/cloudflared/creds/credentials.json 2>/dev/null || echo "⚠️  Não foi possível listar túneis"

# Remove recursos (UNINSTALL - USE COM CAUTELA)
clean:
	@echo "⚠️  Removendo recursos do namespace $(NAMESPACE)..."
	@read -p "Tem certeza? Digite 'sim' para confirmar: " CONFIRM && \
	[ "$$CONFIRM" = "sim" ] || (echo "Cancelado"; exit 1)
	@kubectl delete -f infrastructure/cloudflared/ || true
	@echo "✅ Remoção concluída"
EOF
    log_success "Gerado: $file"
}

# =============================================================================
# EXECUÇÃO
# =============================================================================

# Garante que o script seja executado na raiz do projeto alvo
cd "$(dirname "$0")/.." 2>/dev/null || true

# Executa função principal
main "$@"

exit 0