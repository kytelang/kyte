-- Seed data for the Kyte sandwich shop. Idempotent: clears then inserts.
-- Generated menu: genuine categories + products with self-contained SVG images.
TRUNCATE order_items, orders, cart_items, product_ingredients, product_modifiers,
         products, modifiers, ingredients, categories, users RESTART IDENTITY CASCADE;

INSERT INTO categories (name, description, sort_order) VALUES
  ('Classic', 'Timeless favourites', 1),
  ('Vegetarian', 'Meat-free and delicious', 2),
  ('Wraps', 'Rolled and ready to go', 3),
  ('Sides', 'Perfect little extras', 4),
  ('Drinks', 'Cold, fizzy and hot', 5);

INSERT INTO products (category_id, name, description, price, image_url, is_vegetarian, stock_quantity)
SELECT c.id, v.name, v.description, v.price, v.image_url, v.is_veg, v.stock
FROM (VALUES
  ('Classic', 'Club Classic', 'Triple-decker chicken, bacon, lettuce and tomato.', 6.50, '/img/club.svg', false, 40),
  ('Classic', 'BLT', 'Crispy bacon, lettuce and tomato on toasted sourdough.', 5.25, '/img/blt.svg', false, 50),
  ('Classic', 'Roast Beef', 'Slow-roast beef with horseradish mayo.', 7.00, '/img/beef.svg', false, 30),
  ('Classic', 'Turkey & Swiss', 'Roast turkey, Swiss cheese and cranberry.', 6.75, '/img/turkey.svg', false, 28),
  ('Classic', 'Ham & Cheddar', 'Honey-roast ham with mature cheddar.', 5.75, '/img/ham.svg', false, 36),
  ('Vegetarian', 'Caprese', 'Fresh mozzarella, tomato, basil and balsamic.', 5.75, '/img/caprese.svg', true, 45),
  ('Vegetarian', 'Paneer Tikka', 'Spiced paneer, mint chutney and red onion.', 6.00, '/img/paneer.svg', true, 35),
  ('Vegetarian', 'Avocado Smash', 'Smashed avocado, chilli and lime on rye.', 6.25, '/img/avocado.svg', true, 30),
  ('Vegetarian', 'Halloumi Stack', 'Grilled halloumi, roasted pepper and pesto.', 6.50, '/img/halloumi.svg', true, 26),
  ('Wraps', 'Chicken Caesar Wrap', 'Grilled chicken, cos lettuce and Caesar dressing.', 6.75, '/img/caesar.svg', false, 32),
  ('Wraps', 'Falafel Wrap', 'Falafel, hummus and pickled veg in a warm wrap.', 5.50, '/img/falafel.svg', true, 40),
  ('Wraps', 'Veggie Hummus Wrap', 'Hummus, roasted veg and rocket.', 5.25, '/img/veggiewrap.svg', true, 34),
  ('Sides', 'Skin-on Fries', 'Golden skin-on fries with sea salt.', 3.00, '/img/fries.svg', true, 60),
  ('Sides', 'Side Salad', 'Mixed leaves, cucumber and cherry tomato.', 3.50, '/img/salad.svg', true, 40),
  ('Sides', 'Kettle Crisps', 'Hand-cooked sea-salt crisps.', 1.50, '/img/crisps.svg', true, 80),
  ('Sides', 'Soup of the Day', 'Ask at the counter, served with bread.', 4.25, '/img/soup.svg', true, 25),
  ('Drinks', 'Cola', 'Chilled classic cola.', 1.80, '/img/cola.svg', true, 100),
  ('Drinks', 'Orange Juice', 'Freshly squeezed orange juice.', 2.20, '/img/oj.svg', true, 50),
  ('Drinks', 'Flat White', 'Double-shot flat white.', 2.80, '/img/coffee.svg', true, 50),
  ('Drinks', 'Sparkling Water', 'Sparkling spring water.', 1.60, '/img/water.svg', true, 90)
) AS v(cat, name, description, price, image_url, is_veg, stock)
JOIN categories c ON c.name = v.cat;

INSERT INTO modifiers (name, options, extra_cost) VALUES
  ('Bread',  '["White","Whole Wheat","Sourdough","Gluten-Free"]', 0.00),
  ('Cheese', '["Cheddar","Swiss","Mozzarella","None"]',           0.75),
  ('Sauce',  '["Mayo","Mustard","Chipotle","Pesto"]',             0.00),
  ('Extras', '["Avocado","Extra Bacon","Fried Egg"]',             1.25);

-- Sandwiches, wraps and salads take Bread/Cheese/Sauce; drinks and crisps do not.
INSERT INTO product_modifiers (product_id, modifier_id, is_required, max_choices)
SELECT p.id, m.id,
       (m.name = 'Bread') AS is_required,
       CASE WHEN m.name = 'Extras' THEN 3 ELSE 1 END AS max_choices
FROM products p
CROSS JOIN modifiers m
WHERE m.name IN ('Bread','Cheese','Sauce')
  AND p.category_id IN (SELECT id FROM categories WHERE name IN ('Classic','Vegetarian','Wraps'));

-- A demo admin. password_hash is a placeholder; real registration hashes with a KDF.
INSERT INTO users (email, password_hash, full_name, role)
VALUES ('admin@shop.test', 'seed-not-a-real-hash', 'Shop Admin', 'admin');
