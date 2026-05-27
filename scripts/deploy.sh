#!/bin/bash
# =============================================================================
# SCRIPT: deploy.sh (VERSÃO CORRIGIDA)
# DESCRIÇÃO: Aplica manifests do Cloudflare Tunnel no cluster k3s
#            EXCLUINDO arquivos de Kustomize/GitOps do apply direto
# =============================================================================

set -euo pipefail

# Configurações
readonly NAMESPACE="infrastructure"
readonly TIMEOUT="120s"
readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

# Cores
readonly GREEN='\033[0;32m'
readonly RED='\033[0;31m'
readonly YELLOW='\033[1;33m'
readonly NC='\033[0m'

log() { echo -e "${GREEN}[DEPLOY]${NC} $1"; }
warn() { echo -e "${YELLOW}[AVISO]${NC} $1"; }
error() { echo -e "${RED}[ERRO]${NC} $1" >&2; }

# =============================================================================
# VALIDAÇÕES
# =============================================================================

check_prerequisites() {
    log "Verificando pré-requisitos..."
    
    command -v kubectl >/dev/null 2>&1 || { error "kubectl não encontrado"; exit 1; }
    
    if ! kubectl cluster-info >/dev/null 2>&1; then
        error "Não foi possível conectar ao cluster Kubernetes"
        exit 1
    fi
    log "✓ Cluster acessível"
    
    # Verifica token (aceita tanto o placeholder quanto token real para flexibilidade)
    local secret_file="${PROJECT_ROOT}/infrastructure/cloudflared/02-secret-tunnel.yaml"
    if [[ -f "$secret_file" ]] && grep -q "token:" "$secret_file"; then
        if grep -q "REPLACE_ME_WITH_CLOUDFLARE_TUNNEL_TOKEN" "$secret_file"; then
            warn "Token ainda é placeholder. O deploy pode falhar na autenticação."
            warn "Edite $secret_file e insira seu token real da Cloudflare."
        else
            log "✓ Token configurado"
        fi
    else
        warn "Arquivo de secret não encontrado ou sem token. Verifique manualmente."
    fi
}

# =============================================================================
# APLICAÇÃO DE MANIFESTS (CORRIGIDA)
# =============================================================================

apply_manifests() {
    local dir="$1"
    log "Aplicando manifests de: $dir"
    
    # Lista arquivos YAML excluindo kustomization.yaml e arquivos de template
    local files=()
    for f in "$dir"/*.yaml; do
        [[ -f "$f" ]] || continue
        local basename=$(basename "$f")
        # Pula arquivos que NÃO são recursos Kubernetes aplicáveis diretamente
        case "$basename" in
            kustomization.yaml|Kustomization.yaml)
                warn "Ignorando $basename (use 'kubectl apply -k' ou GitOps)"
                continue
                ;;
            *-template.yaml|*.template.yaml)
                warn "Ignorando $basename (arquivo template)"
                continue
                ;;
        esac
        files+=("$f")
    done
    
    # Ordena e aplica
    if [[ ${#files[@]} -eq 0 ]]; then
        warn "Nenhum manifest válido encontrado em $dir"
        return 0
    fi
    
    for manifest in $(printf '%s\n' "${files[@]}" | sort); do
        log "→ $(basename "$manifest")"
        if ! kubectl apply -f "$manifest"; then
            error "Falha ao aplicar $manifest"
            return 1
        fi
    done
}

# =============================================================================
# VERIFICAÇÃO DE STATUS
# =============================================================================

wait_ready() {
    log "Aguardando recursos estarem prontos..."
    
    # Verifica se o Deployment existe antes de aguardar
    if ! kubectl get deployment cloudflared -n "$NAMESPACE" >/dev/null 2>&1; then
        warn "Deployment 'cloudflared' não encontrado. Verifique se os manifests foram aplicados."
        return 1
    fi
    
    # Aguarda Deployment ficar disponível
    if ! kubectl wait --for=condition=available \
        deployment/cloudflared -n "$NAMESPACE" --timeout="$TIMEOUT" 2>/dev/null; then
        error "Timeout aguardando cloudflared ficar disponível"
        log "Verificando status do rollout..."
        kubectl rollout status deployment/cloudflared -n "$NAMESPACE" --timeout=30s || true
        return 1
    fi
    log "✓ cloudflared pronto"
    
    # Pequena pausa para logs estabilizarem
    sleep 3
    
    # Verifica logs por erros críticos
    if kubectl logs -l app=cloudflared -n "$NAMESPACE" --tail=30 2>/dev/null | grep -qiE "error|fail|unauthorized|invalid"; then
        warn "Possíveis erros nos logs. Verifique com:"
        echo "  kubectl logs -l app=cloudflared -n $NAMESPACE -f"
    else
        log "✓ Logs iniciais sem erros críticos"
    fi
}

# =============================================================================
# PÓS-DEPLOY: INFORMAÇÕES ÚTEIS
# =============================================================================

show_post_deploy_info() {
    echo ""
    log "✅ Deploy concluído com sucesso!"
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "📋 PRÓXIMOS PASSOS"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
    echo "1️⃣  Configure o DNS no FreeDomain/Cloudflare:"
    echo "    • Acesse https://domain.digitalplat.org/"
    echo "    • Aponte seu domínio para os nameservers da Cloudflare"
    echo "    • No Zero Trust > Networks > Tunnels, adicione uma rota:"
    echo "      Hostname: app.seudominio.dpdns.org"
    echo "      Service:  http://exemplo-app-svc:80"
    echo ""
    echo "2️⃣  Monitore o túnel:"
    echo "    kubectl logs -l app=cloudflared -n $NAMESPACE -f"
    echo ""
    echo "3️⃣  Teste a conectividade:"
    echo "    # Health check interno"
    echo "    kubectl port-forward -n $NAMESPACE deploy/cloudflared 2000:2000 &"
    echo "    curl http://localhost:2000/ready"
    echo ""
    echo "    # Acesso externo (após configurar DNS)"
    echo "    curl -I https://app.seudominio.dpdns.org"
    echo ""
    echo "4️⃣  Verifique status dos recursos:"
    echo "    kubectl get all -n $NAMESPACE -l app=cloudflared"
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "🔧 COMANDOS ÚTEIS"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  # Logs em tempo real"
    echo "  kubectl logs -l app=cloudflared -n $NAMESPACE -f"
    echo ""
    echo "  # Reiniciar tunnel (se necessário)"
    echo "  kubectl rollout restart deployment/cloudflared -n $NAMESPACE"
    echo ""
    echo "  # Remover tudo (UNINSTALL)"
    echo "  kubectl delete -f ${PROJECT_ROOT}/infrastructure/cloudflared/04-deployment-cloudflared.yaml"
    echo "  kubectl delete -f ${PROJECT_ROOT}/infrastructure/cloudflared/03-configmap-cloudflared.yaml"
    echo "  kubectl delete -f ${PROJECT_ROOT}/infrastructure/cloudflared/02-secret-tunnel.yaml"
    echo "  kubectl delete -f ${PROJECT_ROOT}/infrastructure/cloudflared/01-namespace.yaml"
    echo ""
}

# =============================================================================
# MAIN
# =============================================================================

main() {
    log "Iniciando deploy do Cloudflare Tunnel..."
    echo "   Projeto: ${PROJECT_ROOT}"
    echo "   Namespace: $NAMESPACE"
    echo ""
    
    check_prerequisites
    apply_manifests "${PROJECT_ROOT}/infrastructure/cloudflared"
    wait_ready
    show_post_deploy_info
}

# Executa
main "$@"