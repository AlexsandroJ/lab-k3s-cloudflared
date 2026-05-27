# =============================================================================
# ARQUIVO: README.md
# PROJETO: lab
# DESCRIÇÃO: Documentação do projeto
# DOMÍNIO: lablocal.dpdns.org
# TÚNEL: k3s-homelab
# GERADO EM: 20260527_093103
# =============================================================================
# ⚠️  ESTE ARQUIVO FOI GERADO AUTOMATICAMENTE.
#    Alterações manuais podem ser sobrescritas ao regerar.
#    Para personalizar, edite após a geração ou modifique este script.
# =============================================================================

# lab - k3s + Cloudflare Tunnel + FreeDomain

> Deploy automatizado de serviços no k3s expostos via Cloudflare Tunnel, usando domínio gratuito do FreeDomain.

## 📋 Pré-requisitos

- Cluster k3s funcionando e `kubectl` configurado
- Conta na [Cloudflare Zero Trust](https://one.dash.cloudflare.com/)
- Domínio registrado no [FreeDomain](https://domain.digitalplat.org/) apontando para nameservers da Cloudflare

## 🚀 Deploy Rápido

```bash
# 1. Gere os manifests (se ainda não fez)
./scripts/generate-manifests.sh lab lablocal.dpdns.org k3s-homelab

# 2. Edite o secret com seu token real
#    Obtenha o token em: Cloudflare Zero Trust > Networks > Tunnels > Configure
nano lab-k3s-cloudflared/infrastructure/cloudflared/02-secret-tunnel.yaml

# 3. Execute o deploy
./scripts/deploy.sh
```

## 📁 Estrutura de Arquivos

```
lab-k3s-cloudflared/
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
```

## 🔧 Personalizando para Sua Aplicação

1. Crie seu manifesto de app em `infrastructure/apps/seu-app/`
2. Adicione regra de ingress no `03-configmap-cloudflared.yaml`:
   ```yaml
   ingress:
     - hostname: "lablocal.dpdns.org"
       service: http://seu-app-svc:80
       path: /
   ```
3. Aplique: `kubectl apply -f infrastructure/apps/seu-app/`

## 🔍 Debug e Monitoramento

```bash
# Ver status dos pods
kubectl get pods -n infrastructure -l app=cloudflared

# Logs em tempo real
kubectl logs -l app=cloudflared -n infrastructure -f

# Testar health check interno
kubectl port-forward -n infrastructure deploy/cloudflared 2000:2000 &
curl http://localhost:2000/ready

# Verificar métricas Prometheus
curl http://localhost:2000/metrics
```

## 🔐 Segurança

- ✅ Token armazenado em Secret (não em plain text)
- ✅ Container roda como usuário não-root
- ✅ Root filesystem em modo leitura-only
- ✅ Capabilities Linux removidas
- ✅ Sem portas abertas no firewall (túnel outbound)

## 🔄 Atualizações

### Atualizar regras de ingress (sem downtime):
```bash
# Edite 03-configmap-cloudflared.yaml
kubectl apply -f infrastructure/cloudflared/03-configmap-cloudflared.yaml
# cloudflared recarrega config automaticamente em ~30s
```

### Atualizar versão do cloudflared:
```bash
# Edite 04-deployment-cloudflared.yaml: image: cloudflare/cloudflared:v2024.x.x
kubectl apply -f infrastructure/cloudflared/04-deployment-cloudflared.yaml
# Rollout automático com zero downtime
```

## 🗑️ Remoção (Uninstall)

```bash
kubectl delete -f infrastructure/cloudflared/
# Ou, para remover tudo do namespace:
kubectl delete namespace infrastructure
```

## 📚 Referências

- [Cloudflare Tunnel Docs](https://developers.cloudflare.com/cloudflare-one/connections/connect-apps/)
- [FreeDomain](https://github.com/DigitalPlatDev/FreeDomain)
- [k3s Documentation](https://docs.k3s.io/)
- [Kubernetes Secrets Best Practices](https://kubernetes.io/docs/concepts/configuration/secret/)

---
*Gerado automaticamente em 20260527_093103 por generate-manifests.sh*
