# Docker-Service-Manager
一个基于 PowerShell 的 Docker 本地服务管理工具集。目前内置 **MySQL 单实例管理器**，支持容器创建、运维、备份、恢复、用户权限、远程导入、监控诊断等完整生命周期管理。
[![Docker](https://img.shields.io/badge/Docker-Desktop%2FEngine-blue)](https://www.docker.com/)

**零依赖客户端**：所有 MySQL 操作通过 `docker exec` 调用容器内工具完成，无需在宿主机安装 MySQL
**安全凭据**：root 密码通过 DPAPI 加密保存到项目目录 `.mysqlcred`，脚本中不记录明文密码

## 运行方式

### 方式一：创建新实例

在仓库根目录右键运行 `mysql-manager.ps1`，选择 `[0] 创建/启动 MySQL 容器`。

### 方式二：管理已有实例

进入实例目录（如 `mysql3308`），运行该目录下的 `mysql-manager.ps1`，自动进入运维菜单。

### 方式三：命令行运行

```powershell
# 创建新实例
.\mysql-manager.ps1

# 管理已有实例
cd mysql3308
.\mysql-manager.ps1
```

> 提示：右键运行后窗口会在操作结束后暂停，避免一闪而过。
>
## 主菜单架构

```mermaid
flowchart TD
    A[运行 mysql-manager.ps1] --> B{所在目录}
    B -->|仓库根目录| C[实例创建菜单]
    B -->|mysql3308 等实例目录| D[实例运维菜单]
    C --> C0[0. 创建/启动容器]
    D --> D1[1. 容器运维中心]
    D --> D2[2. 连接 MySQL 终端]
    D --> D3[3. 数据库管理]
    D --> D4[4. SQL 文件操作]
    D --> D5[5. 导出数据库/表]
    D --> D6[6. 用户与权限管理]
    D --> D7[7. 表数据查看]
    D --> D8[8. 系统工具]
    D --> DQ[Q. 退出]
```

---

## 功能模块

### 1. 容器运维中心

```mermaid
flowchart LR
    subgraph 容器运维中心
        A[查看/修改配置]
        B[查看容器状态]
        C[查看/导出日志]
        D[查看资源占用]
        E[停止/删除容器]
    end
```

### 2. 数据库管理

```mermaid
flowchart TD
    A[选择数据库管理] --> B[查看所有数据库]
    A --> C[创建数据库]
    A --> D[删除数据库]
```

### 3. SQL 文件操作

```mermaid
flowchart TD
    A[SQL 文件操作] --> B[执行 SQL 文件]
    A --> C[导入 SQL 文件]
    A --> D[从远程 MySQL 导入]
```

### 4. 导出流程

```mermaid
flowchart TD
    A[选择 5. 导出数据库/表] --> B[列出所有数据库]
    B --> C{选择模式}
    C -->|A| D[导出所有数据库]
    C -->|S| E[选择部分数据库]
    C -->|M| F[手动输入数据库名]
    E --> G[进入表级选择]
    G -->|A| H[导出整个数据库]
    G -->|S| I[选择部分表]
    G -->|Z| J[指定表名]
    H --> K{选择格式}
    I --> K
    J --> K
    K -->|S| L[导出 .sql]
    K -->|C| M[导出 .csv]
    K -->|B| N[同时导出 .sql + .csv]
```

---

## 
