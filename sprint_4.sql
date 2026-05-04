-- NIVELL 1 --

-- Exercici 1: Consulta sobre Taula no Optimitzada (Diagnòstic)


SELECT tc.transaction_id,
       c.company_name,
       c.country
FROM `sprint3_silver.transactions_clean` AS tc
JOIN `sprint3_silver.companies_clean` AS c
ON tc.business_id = c.company_id
WHERE declined = 0;

--

SELECT tc.transaction_id,
       c.company_name,
       c.country
FROM `sprint3_silver.transactions_clean` AS tc
JOIN `sprint3_silver.companies_clean` AS c
ON tc.business_id = c.company_id
WHERE c.country = 'Germany' AND 
date(`timestamp`) = '2022-03-12'
AND declined = 0;


-- Exercici 2: Re-arquitectura i Optimització de l'Emmagatzematge (Partition & Cluster)

-- creació taula intermitja
CREATE OR REPLACE TABLE `sprint3-analytics-arnau-rg.sprint3_silver.transactions_recent`
AS 
      SELECT * EXCEPT(`timestamp`),
             TIMESTAMP_SUB(CURRENT_TIMESTAMP(), 
                           INTERVAL CAST(RAND()*50 AS INT64) DAY) AS timestamp_50_days
      FROM `sprint3_silver.transactions_clean`;


-- creació taula optimitzada
CREATE OR REPLACE TABLE `sprint3-analytics-arnau-rg.sprint3_gold.fact_transactions_optimized` 
PARTITION BY DATE(timestamp_50_days)
CLUSTER BY business_id
AS 
SELECT *
FROM `sprint3-analytics-arnau-rg.sprint3_silver.transactions_recent`;


--

SELECT * FROM `sprint3-analytics-arnau-rg.sprint3_gold.fact_transactions_optimized` ;


-- Exercici 3: La Prova del Cotó (Benchmark)

SELECT * 
FROM `sprint3-analytics-arnau-rg.sprint3_silver.transactions_recent`
WHERE DATE(timestamp_50_days) = TIMESTAMP_SUB(DAYtimestamp_50_days, INTERVAL 30 DAY);


SELECT * 
FROM `sprint3-analytics-arnau-rg.sprint3_gold.fact_transactions_optimized`
WHERE DATE(timestamp_50_days) = TIMESTAMP_SUB(DAYtimestamp_50_days, INTERVAL 30 DAY);


-- Exercici 4: Smart Caching (Vistes Materialitzades)

CREATE MATERIALIZED VIEW  `sprint3-analytics-arnau-rg.sprint3_gold.my_daily_sales`
AS
SELECT DATE(timestamp_50_days) AS fecha, sum(amount) AS total_sales
FROM `sprint3_gold.fact_transactions_optimized`
WHERE DECLINED = 0
GROUP BY DATE(timestamp_50_days); 


SELECT * 
FROM `sprint3-analytics-arnau-rg.sprint3_gold.my_daily_sales`;

-- NIVELL 2 --


-- Exercici 1: Perfilat de Clients VIP (Mètriques Agregades amb CTEs)

WITH VIP_Stats AS (
                    SELECT user_id, 
                    ROUND(SUM(amount),2) AS despesa_total, 
                    COUNT(*) AS num_compras, 
                    ROUND(AVG(amount),2) AS tiquet_mig, 
                    MAX(amount) AS compra_maxima
FROM `sprint3-analytics-arnau-rg.sprint3_gold.fact_transactions_optimized`
WHERE declined = 0
GROUP BY user_id
HAVING despesa_total > 500)

SELECT d.user_id, 
       CONCAT (d.name,' ',d.surname) AS nom_complet, 
       d.email, 
       vs.num_compras, 
       vs.tiquet_mig, 
       vs.compra_maxima,
       vs.despesa_total
FROM `sprint3-analytics-arnau-rg.sprint3_silver.users_combined` AS d
JOIN VIP_Stats AS vs
ON d.user_id = vs.user_id
ORDER BY despesa_total DESC;


-- Exercici 2: Anàlisi de Tendències (Window Functions sobre Vistes)

SELECT *, ROUND(((vendes_avui - vendes_ahir)/ vendes_ahir), 2) * 100 AS diff_percentual
FROM 
  (SELECT fecha, 
        ROUND(total_sales,2) AS vendes_avui, 
        ROUND(LAG(total_sales) OVER (ORDER BY fecha ASC),2) AS vendes_ahir
  FROM `sprint3-analytics-arnau-rg.sprint3_gold.my_daily_sales`) AS t_vendas
ORDER BY fecha ASC;


-- Exercici 3: Totals Acumulats (Running Totals sobre Vistes)

SELECT fecha, 
       ROUND(total_sales) AS vendes_del_dia,
       ROUND(SUM (total_sales) OVER (PARTITION BY EXTRACT(YEAR FROM fecha) ORDER BY fecha ASC, fecha ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW),2) AS vendes_acumulades
FROM `sprint3-analytics-arnau-rg.sprint3_gold.my_daily_sales`
ORDER BY fecha ASC;



-- Exercici 4: Fidelització i Valor del Client (Filtratge Avançat)

WITH tercera_compra AS (
     SELECT user_id, 
             ROW_NUMBER() OVER (PARTITION BY user_id ORDER BY timestamp_50_days ASC) AS list_compra,
             timestamp_50_days AS data_tercera_compra, 
             amount AS import_tercera_compra
     FROM `sprint3-analytics-arnau-rg.sprint3_gold.fact_transactions_optimized`
     WHERE declined = 0
     QUALIFY list_compra = 3),

     mitja_trans AS (SELECT user_id, ROUND(AVG(amount),2) AS mitjana_tres_primeres_trans
FROM 
    (SELECT user_id, 
            ROW_NUMBER() OVER (PARTITION BY user_id ORDER BY timestamp_50_days ASC) lista,
            amount
    FROM `sprint3-analytics-arnau-rg.sprint3_gold.fact_transactions_optimized`
    WHERE declined = 0
    QUALIFY lista <=3) AS d
GROUP BY user_id)

SELECT d.user_id, 
       CONCAT(d.name, ' ', d.surname) AS nom_complet,
       d.email, 
       tc.data_tercera_compra, 
       tc.import_tercera_compra,
       mt.mitjana_tres_primeres_trans
FROM tercera_compra AS tc
JOIN `sprint3_silver.users_combined` AS d
ON tc.user_id = d.user_id
JOIN mitja_trans AS mt
ON d.user_id = mt.user_id;



-- NIVELL 3 --


-- Exercici 1: Desanidament i Aplanament de Dades (Unnesting)

CREATE TABLE IF NOT EXISTS `sprint3_gold.dim_transactions_flat`
AS 

SELECT ti.transaction_id,
       DATE(ti.timestamp_50_days) AS fecha_transaccion,
       ti.amount AS total_ticket, 
       d.product_id,
       d.name AS product_name,
       d.price AS product_price
FROM `sprint3_gold.fact_transactions_optimized` AS ti 
CROSS JOIN UNNEST(SPLIT(product_ids, ', ')) AS product
JOIN `sprint3_silver.products_clean` AS d
ON SAFE_CAST(product AS INT64) = SAFE_CAST (d.product_id AS INT64)
WHERE ti.declined = 0
ORDER BY ti.transaction_id ASC;
  

SELECT * FROM `sprint3_gold.dim_transactions_flat`;         


-- Exercici 2: El Rànquing de Vendes (Agregació Simple)

SELECT product_name, 
       count(*) AS num_vendes
FROM `sprint3-analytics-arnau-rg.sprint3_gold.dim_transactions_flat`
GROUP BY product_name
ORDER BY num_vendes DESC
LIMIT 5;


-- Exercici 3: Automatització del Pipeline i Visualització

CREATE OR REPLACE FUNCTION `sprint3-analytics-arnau-rg`.sprint3_gold.calculate_tax(price FLOAT64)
RETURNS FLOAT64
AS (price * 0.21);

--

CREATE OR REPLACE TABLE `sprint3_gold.dim_transactions_flat`
AS 

SELECT ti.transaction_id,
       DATE(ti.timestamp_50_days) AS fecha_transaccion,
       ti.amount AS total_ticket, 
       d.product_id,
       d.name AS product_name,
       d.price AS product_price,
       ROUND(d.price + `sprint3-analytics-arnau-rg`.sprint3_gold.calculate_tax (d.price),2) AS product_price_tax_inc
FROM `sprint3_gold.fact_transactions_optimized` AS ti 
CROSS JOIN UNNEST(SPLIT(product_ids, ', ')) AS product
JOIN `sprint3_silver.products_clean` AS d
ON SAFE_CAST(product AS INT64) = SAFE_CAST (d.product_id AS INT64)
WHERE ti.declined = 0
ORDER BY ti.transaction_id ASC;

SELECT * FROM `sprint3-analytics-arnau-rg.sprint3_gold.dim_transactions_flat`;

