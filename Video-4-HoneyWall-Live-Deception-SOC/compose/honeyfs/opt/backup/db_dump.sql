-- MySQL dump 10.13  Distrib 8.0.36, for Linux (x86_64)
-- Host: localhost    Database: corp_crm
-- ------------------------------------------------------
CREATE TABLE `customers` (
  `id` int NOT NULL AUTO_INCREMENT,
  `name` varchar(120) NOT NULL,
  `email` varchar(160) NOT NULL,
  `card_last4` char(4) DEFAULT NULL,
  PRIMARY KEY (`id`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

INSERT INTO `customers` VALUES
(1,'Acme Logistics','ap@acme-logistics.example','4242'),
(2,'Northwind Traders','billing@northwind.example','1881'),
(3,'Contoso Health','finance@contoso-health.example','0005');
-- Dump completed on 2026-10-12  2:14:07
