# =============================================================================
# ARQUIVO: deploy.sh
# PROJETO: lab
# DESCRIÇÃO: Script de deploy automatizado com validações
# DOMÍNIO: lablocal.dpdns.org
# TÚNEL: k3s-homelab
# GERADO EM: 20260527_093103
# =============================================================================
# ⚠️  ESTE ARQUIVO FOI GERADO AUTOMATICAMENTE.
#    Alterações manuais podem ser sobrescritas ao regerar.
#    Para personalizar, edite após a geração ou modifique este script.
# =============================================================================

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
