CREATE DATABASE IF NOT EXISTS envs;
USE envs;

CREATE TABLE IF NOT EXISTS scripts (
    id INT AUTO_INCREMENT PRIMARY KEY,
    name VARCHAR(100) NOT NULL,
    filename VARCHAR(255) NOT NULL,
    description VARCHAR(255) NULL,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE IF NOT EXISTS environments (
    id INT AUTO_INCREMENT PRIMARY KEY,
    name VARCHAR(100) NOT NULL,
    cpu_percent INT NOT NULL,
    memory_mb INT NOT NULL,
    io_mbps INT NOT NULL,
    mode ENUM('cmd', 'script') NOT NULL,
    command TEXT NULL,
    script_id INT NULL,
    pid INT NULL,
    status ENUM(
        'creating', 'running', 'finished', 'error', 'stopped'
    ) NOT NULL DEFAULT 'creating',
    exit_code INT NULL,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    FOREIGN KEY (script_id) REFERENCES scripts(id)
);