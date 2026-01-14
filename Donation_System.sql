-- 1. DATABASE SETUP
DROP DATABASE IF EXISTS FoodExpirySystem;
CREATE DATABASE FoodExpirySystem;
USE FoodExpirySystem;

-- 2. CATEGORIES TABLE (Required for 3NF Normalization)
CREATE TABLE Categories (
    category_id INT AUTO_INCREMENT PRIMARY KEY,
    category_name VARCHAR(50) NOT NULL UNIQUE,
    storage_type ENUM('Frozen', 'Refrigerated', 'Dry') NOT NULL
);

-- 3. PRODUCTS TABLE
CREATE TABLE Products (
    product_id INT AUTO_INCREMENT PRIMARY KEY,
    product_name VARCHAR(100) NOT NULL,
    sku VARCHAR(50) UNIQUE NOT NULL,
    category_id INT NOT NULL,
    CONSTRAINT fk_category
        FOREIGN KEY (category_id) REFERENCES Categories(category_id)
        ON UPDATE CASCADE
);

-- 4. INVENTORY BATCHES TABLE
CREATE TABLE Inventory (
    batch_id INT AUTO_INCREMENT PRIMARY KEY,
    product_id INT NOT NULL,
    quantity INT NOT NULL CHECK (quantity >= 0),
    expiry_date DATE NOT NULL,
    status ENUM('Available', 'Donated', 'Wasted') DEFAULT 'Available',
    CONSTRAINT fk_product
        FOREIGN KEY (product_id) REFERENCES Products(product_id)
        ON UPDATE CASCADE
);

-- 5. DONATION RECIPIENTS (The NGOs)
CREATE TABLE Recipients (
    recipient_id INT AUTO_INCREMENT PRIMARY KEY,
    org_name VARCHAR(100) NOT NULL,
    contact_phone VARCHAR(20),
    address VARCHAR(255)
);

-- 6. DONATIONS LOG
CREATE TABLE Donations (
    donation_id INT AUTO_INCREMENT PRIMARY KEY,
    batch_id INT NOT NULL,
    recipient_id INT NOT NULL,
    donation_date DATETIME DEFAULT CURRENT_TIMESTAMP,
    quantity_donated INT NOT NULL CHECK (quantity_donated > 0),
    CONSTRAINT fk_donation_batch
        FOREIGN KEY (batch_id) REFERENCES Inventory(batch_id),
    CONSTRAINT fk_recipient
        FOREIGN KEY (recipient_id) REFERENCES Recipients(recipient_id)
);

-- 7. WASTE LOG
CREATE TABLE WasteLog (
    waste_id INT AUTO_INCREMENT PRIMARY KEY,
    batch_id INT NOT NULL,
    quantity_wasted INT NOT NULL,
    log_date DATETIME DEFAULT CURRENT_TIMESTAMP,
    reason VARCHAR(50) DEFAULT 'Expired',
    CONSTRAINT fk_waste_batch
        FOREIGN KEY (batch_id) REFERENCES Inventory(batch_id)
);

-- 8. INDEXES 
-- Indexes speed up the search for expiring items.
CREATE INDEX idx_expiry_date ON Inventory(expiry_date);
CREATE INDEX idx_status ON Inventory(status);

-- DATA INSERTION (DML)

INSERT INTO Categories (category_name, storage_type) VALUES 
('Dairy', 'Refrigerated'),
('Bakery', 'Dry'),
('Canned Goods', 'Dry'),
('Meat', 'Frozen');

INSERT INTO Products (product_name, sku, category_id) VALUES 
('Whole Milk', 'MILK01', 1),
('Sourdough Bread', 'BRD01', 2),
('Tomato Soup', 'CAN01', 3),
('Chicken Breast', 'MEAT01', 4);

-- Simulating dates: Some expired, some fresh
INSERT INTO Inventory (product_id, quantity, expiry_date, status) VALUES 
(1, 50, DATE_ADD(CURRENT_DATE, INTERVAL 5 DAY), 'Available'),   -- Milk (Expiring Soon)
(2, 20, DATE_SUB(CURRENT_DATE, INTERVAL 2 DAY), 'Available'),   -- Bread (Expired)
(3, 100, DATE_ADD(CURRENT_DATE, INTERVAL 365 DAY), 'Available'),-- Soup (Fresh)
(4, 10, DATE_SUB(CURRENT_DATE, INTERVAL 10 DAY), 'Available');  -- Chicken (Expired)

INSERT INTO Recipients (org_name, address) VALUES 
('Edhi Foundation', 'Karachi'),
('Chhipa Welfare', 'Lahore');

-- VIEWS & REPORTS


-- VIEW 1: Donation Candidates (Expiring in 7 days but not yet expired)
CREATE VIEW View_DonationCandidates AS
SELECT 
    i.batch_id, p.product_name, c.category_name, i.quantity, i.expiry_date,
    DATEDIFF(i.expiry_date, CURRENT_DATE) AS days_left
FROM Inventory i
JOIN Products p ON i.product_id = p.product_id
JOIN Categories c ON p.category_id = c.category_id
WHERE i.status = 'Available'
  AND i.expiry_date BETWEEN CURRENT_DATE AND DATE_ADD(CURRENT_DATE, INTERVAL 7 DAY);

-- REQUIRED LOGIC: SUBQUERIES & PROCEDURES


-- Logic: Find products that have more quantity than the average inventory batch.
SELECT p.product_name, i.quantity
FROM Inventory i
JOIN Products p ON i.product_id = p.product_id
WHERE i.quantity > (SELECT AVG(quantity) FROM Inventory);

-- STORED PROCEDURE (Transactional Donation)
-- This safely moves stock from Inventory to Donations

DELIMITER //

set sql_safe_updates = 0;

Drop Procedure Process_Donation;

CREATE PROCEDURE Process_Donation(
    IN p_batch_id INT,
    IN p_recipient_id INT,
    IN p_quantity INT
)
BEGIN
    DECLARE v_current_qty INT;
    
    -- Check current stock
    SELECT quantity INTO v_current_qty FROM Inventory WHERE batch_id = p_batch_id;
    
    IF v_current_qty >= p_quantity THEN
        START TRANSACTION;
            -- 1. Log the donation
            INSERT INTO Donations (batch_id, recipient_id, quantity_donated)
            VALUES (p_batch_id, p_recipient_id, p_quantity);
            
            -- 2. Update Inventory
            UPDATE Inventory 
            SET quantity = quantity - p_quantity,
                status = IF((quantity - p_quantity) = 0, 'Donated', status)
            WHERE batch_id = p_batch_id;
        COMMIT;
        SELECT 'Donation Processed Successfully' AS Status;
    ELSE
        SELECT 'Error: Insufficient Quantity' AS Status;
    END IF;
END //

-- PROCEDURE FOR EXPIRED ITEMS
-- Moves expired items to WasteLog automatically
CREATE PROCEDURE Flush_Expired_Items()
BEGIN
    START TRANSACTION;
        -- 1. Copy to Waste Log
        INSERT INTO WasteLog (batch_id, quantity_wasted, reason)
        SELECT batch_id, quantity, 'Expired Auto-Log'
        FROM Inventory 
        WHERE expiry_date < CURRENT_DATE AND status = 'Available';
        
        -- 2. Update Inventory Status
        UPDATE Inventory 
        SET status = 'Wasted', quantity = 0
        WHERE expiry_date < CURRENT_DATE AND status = 'Available';
    COMMIT;
    SELECT 'Expired items flushed to Waste Log' AS Message;
END //

DELIMITER ;

--  SECURITY & USER MANAGEMENT 


CREATE USER 'food_admin'@'localhost' IDENTIFIED BY 'SecurePass123';

-- Grant access only to the necessary tables (Principle of Least Privilege)
GRANT SELECT, INSERT, UPDATE ON FoodExpirySystem.* TO 'food_admin'@'localhost';

FLUSH PRIVILEGES;

-- TESTING AREA

-- 1. View Candidates
SELECT * FROM View_DonationCandidates;

-- 2. Run the Expiry Flusher
CALL Flush_Expired_Items();

-- 3. Check that expired items (Bread & Chicken) are now Wasted
SELECT * FROM Inventory;
SELECT * FROM WasteLog;

-- 4. Process a Donation
CALL Process_Donation(1, 1, 10); -- Donate 10 Milk to Edhi Foundation
SELECT * FROM Donations;


