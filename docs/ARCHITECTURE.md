# Platform Architecture

## Overview

A data platform on GKE providing centralized identity management, secrets management, object storage, distributed computing, and SQL analytics.

```mermaid
graph TB
    subgraph External["External Access"]
        User[👤 User]
    end
    
    subgraph GKE["GKE Cluster"]
        subgraph Identity["Identity & Security"]
            KC[🔐 Keycloak<br/>Identity Provider]
            Vault[🔑 Vault<br/>Secrets Manager]
        end
        
        subgraph Storage["Data Storage"]
            MinIO[📦 MinIO<br/>Object Storage]
        end
        
        subgraph Compute["Data Processing"]
            JH[📓 JupyterHub<br/>Notebooks]
            Spark[⚡ Spark<br/>Distributed Compute]
            Dremio[🔍 Dremio<br/>SQL Analytics]
        end
    end
    
    User -->|OIDC| KC
    KC -->|Auth| Vault
    KC -->|Auth| MinIO
    KC -->|Auth| JH
    KC -->|Auth| Dremio
    
    JH -->|STS Credentials| MinIO
    Spark -->|S3 API| MinIO
    Dremio -->|S3 API| MinIO
    
    Vault -->|Secrets| MinIO
    Vault -->|Secrets| Dremio
```

---

## Components

### Identity & Security Layer

#### Keycloak (Identity Provider)
- **Purpose**: Centralized authentication and authorization via OIDC
- **Namespace**: `operators`
- **Storage**: PostgreSQL with 2Gi persistent volume
- **Realm**: `vault` - contains all application users and clients

#### HashiCorp Vault (Secrets Manager)
- **Purpose**: Secure storage for credentials and secrets
- **Namespace**: `vault`
- **Storage**: 1Gi persistent volume
- **Auth**: OIDC via Keycloak

### Data Storage Layer

#### MinIO (Object Storage)
- **Purpose**: S3-compatible object storage for data lake
- **Namespace**: `minio` (tenant), `minio-operator` (operator)
- **Auth**: OIDC via Keycloak + STS for temporary credentials
- **Policies**: Group-based access control

### Data Processing Layer

#### JupyterHub (Interactive Notebooks)
- **Purpose**: Data science environment with per-user notebook servers
- **Namespace**: `jupyterhub` (hub), `jupyterhub-users` (pods)
- **Auth**: OAuth via Keycloak
- **Features**: Auto-injected MinIO STS credentials

#### Spark Operator (Distributed Computing)
- **Purpose**: Run distributed Spark jobs on Kubernetes
- **Namespace**: `operators`
- **Features**: SparkApplication CRD, Spark Connect support
- **Storage**: MinIO via S3A connector

#### Airflow (Workflow Orchestration)
- **Purpose**: Schedule and monitor data pipelines
- **Namespace**: `airflow`
- **Executor**: LocalExecutor (standalone mode)
- **Auth**: Keycloak Auth Manager
- **Storage**: PostgreSQL for metadata

#### Dremio (SQL Analytics)
- **Purpose**: Data lakehouse query engine with SQL interface
- **Namespace**: `dremio`
- **Features**: Query acceleration, data virtualization
- **Storage**: MinIO as data source

---

## Authentication Flow

```mermaid
sequenceDiagram
    participant User
    participant Service as Service<br/>(Vault/MinIO/JupyterHub/Airflow/Dremio)
    participant KC as Keycloak
    
    User->>Service: Access Request
    Service->>KC: Redirect to Login
    User->>KC: Authenticate (username/password)
    KC->>KC: Validate Credentials
    KC->>User: ID Token + Access Token
    User->>Service: Token
    Service->>KC: Validate Token
    KC->>Service: Token Valid + User Groups
    Service->>User: Access Granted
```

### Keycloak Configuration

```mermaid
graph LR
    subgraph Realm["vault Realm"]
        subgraph Clients
            C1[vault]
            C2[minio]
            C3[jupyterhub]
            C4[airflow]
            C5[dremio]
        end
        
        subgraph Groups
            G1[vault-admins]
            G2[minio-access]
            G3[jupyterhub]
            G4[data-science]
            G5[airflow-admin]
            G6[data-engineers]
            G7[data-scientists]
        end
        
        subgraph Users
            U1[admin]
            U2[jupyter-admin]
            U3[jupyter-ds]
        end
    end
    
    U1 --> G1
    U1 --> G2
    U1 --> G3
    U1 --> G5
    
    U2 --> G6
    U3 --> G7
    
    C1 -->|OIDC| Vault[Vault]
    C2 -->|OIDC| MinIO[MinIO]
    C3 -->|OAuth| JH[JupyterHub]
    C4 -->|Keycloak Auth| AF[Airflow]
    C5 -->|OIDC| Dremio[Dremio]
```

---

## Data Flow

### JupyterHub → MinIO (STS Integration)

```mermaid
sequenceDiagram
    participant User
    participant JH as JupyterHub
    participant KC as Keycloak
    participant MinIO
    participant NB as Notebook Pod
    
    User->>JH: Login
    JH->>KC: OAuth Redirect
    User->>KC: Authenticate
    KC->>JH: ID Token
    
    User->>JH: Start Notebook
    JH->>KC: Get Fresh ID Token
    KC->>JH: ID Token (with groups)
    JH->>MinIO: STS AssumeRoleWithWebIdentity
    MinIO->>KC: Validate Token
    KC->>MinIO: Valid + Groups
    MinIO->>JH: Temp Credentials (1hr)
    
    JH->>NB: Spawn Pod with Env Vars
    Note over NB: AWS_ACCESS_KEY_ID<br/>AWS_SECRET_ACCESS_KEY<br/>AWS_SESSION_TOKEN
    
    NB->>MinIO: S3 API Calls
    MinIO->>NB: Data Access
```

### Spark → MinIO (S3A)

```mermaid
sequenceDiagram
    participant User
    participant SparkApp as SparkApplication
    participant Driver as Spark Driver
    participant Executor as Spark Executors
    participant MinIO
    
    User->>SparkApp: Submit Job (YAML)
    SparkApp->>Driver: Create Driver Pod
    Driver->>Executor: Create Executor Pods
    
    Note over Driver,Executor: S3A Config:<br/>fs.s3a.endpoint<br/>fs.s3a.access.key<br/>fs.s3a.secret.key
    
    Driver->>MinIO: Read Data (S3A)
    Executor->>MinIO: Read/Write Data
    MinIO->>Executor: Data Transfer
    Executor->>Driver: Results
```

### Dremio → MinIO (Data Source)

```mermaid
sequenceDiagram
    participant User
    participant Dremio as Dremio Coordinator
    participant Exec as Dremio Executors
    participant MinIO
    
    User->>Dremio: SQL Query
    Dremio->>Dremio: Parse & Plan
    Dremio->>Exec: Distribute Query
    Exec->>MinIO: Read Data (S3)
    MinIO->>Exec: Parquet/Iceberg Files
    Exec->>Dremio: Results
    Dremio->>User: Query Results
```

---

## Namespace Layout

```mermaid
graph TB
    subgraph operators["operators namespace"]
        KC[Keycloak]
        KCO[Keycloak Operator]
        PG[PostgreSQL]
        SparkOp[Spark Operator]
    end
    
    subgraph vault["vault namespace"]
        V[Vault]
    end
    
    subgraph minio-operator["minio-operator namespace"]
        MO[MinIO Operator]
    end
    
    subgraph minio["minio namespace"]
        MT[MinIO Tenant]
    end
    
    subgraph jupyterhub["jupyterhub namespace"]
        Hub[JupyterHub]
        Proxy[Proxy]
    end
    
    subgraph jupyterhub-users["jupyterhub-users namespace"]
        NB1[User Notebooks]
    end
    
    subgraph dremio["dremio namespace"]
        Coord[Coordinator]
        Exec[Executors]
    end
    
    KCO -->|manages| KC
    MO -->|manages| MT
    SparkOp -->|manages| SparkApps[SparkApplications]
    Hub -->|spawns| NB1
```

---

## Persistent Storage

| Component | Volume Size | Data Stored |
|-----------|-------------|-------------|
| PostgreSQL (Keycloak) | 2Gi | Realms, users, clients, sessions |
| Vault | 1Gi | Secrets, policies, auth config |
| MinIO | Configurable | Object data, bucket metadata |
| Dremio | Configurable | Metadata, reflections, job history |

---

## Network Architecture

### Internal DNS

```mermaid
graph LR
    subgraph Services
        KC[keycloak-service.operators.svc.cluster.local:8080]
        V[vault.vault.svc.cluster.local:8200]
        M[minio.minio.svc.cluster.local:443]
        D[dremio-client.dremio.svc.cluster.local:9047]
    end
```

### External Access (Port Forwards)

| Service | Local Port | Remote Port | URL |
|---------|------------|-------------|-----|
| Keycloak | 8080 | 8080 | http://localhost:8080 |
| Vault | 8200 | 8200 | http://localhost:8200 |
| MinIO Console | 9091 | 9443 | https://localhost:9091 |
| MinIO API | 9000 | 443 | https://localhost:9000 |
| JupyterHub | 8000 | 80 | http://localhost:8000 |
| Dremio | 9047 | 9047 | http://localhost:9047 |

---

## Security Model

```mermaid
graph TB
    subgraph Authentication
        SSO[Single Sign-On<br/>via Keycloak OIDC]
        Token[Token-based<br/>JWT Validation]
    end
    
    subgraph Authorization
        Groups[Group-based<br/>Keycloak Groups]
        Policies[Policy-based<br/>MinIO/Vault Policies]
    end
    
    subgraph Secrets
        Central[Centralized<br/>Vault Storage]
        Dynamic[Dynamic<br/>STS Credentials]
        Encrypt[Encrypted<br/>At Rest]
    end
    
    SSO --> Token
    Token --> Groups
    Groups --> Policies
    Central --> Dynamic
    Dynamic --> Encrypt
```

### Access Control Matrix

| Service | Auth Method | Authorization |
|---------|-------------|---------------|
| Keycloak | Username/Password | Realm roles |
| Vault | OIDC or Token | Policies via groups |
| MinIO | OIDC + STS | Policies via groups |
| JupyterHub | OAuth | Group membership |
| Spark | Service Account | K8s RBAC |
| Dremio | OIDC or Local | Dremio roles |
